"""매장 module.

무엇이 어느 매장에 나가 있는지가 이 모듈의 존재 이유다. 재고(`/inventory`)는
"우리가 가진 것"을 창고 기준으로 보고, 여기는 같은 자산을 고객 사이트 기준으로
본다. 두 화면이 같은 `assets` 행을 다른 축으로 읽는다.

브랜드는 분류 코드(CodeGroup "STORE_BRAND")다. 바른치킨·자담치킨처럼 매장이
묶이는 단위이고, 이름이 바뀌어도 FK 라 매장 쪽이 따라온다.

구 서버(CS_Record)의 매장 화면 규칙: 미운영 저장 = 설치 장비를 고른 회수 위치로
(브랜드 회수 · 창고 · 사무실), 납품 세트 단위 장비 설정(없는 S/N 은 등록, 다른
곳의 장비는 이동), 비전동 그리퍼 관리 번호(NG-0001 …) 자동.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Query, status
from sqlalchemy import case, func, select
from sqlalchemy.orm import Session

from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import (
    OPEN_SERVICE_STATUSES,
    AssetStatus,
    AuditAction,
    ModuleKey,
    MovementType,
    ServiceStatus,
)
from app.models.inventory import Asset
from app.models.service import ServiceTicket, ServiceTicketCause
from app.models.store import Store, StoreSet
from app.models.user import User
from app.schemas.common import CodeItemBrief, Message, Page
from app.schemas.store import (
    AssetInStore,
    BrandSummary,
    CategoryCount,
    EquipmentSetupRequest,
    EquipmentSetupResult,
    StoreAssetGroup,
    StoreCloseRequest,
    StoreCloseResult,
    StoreCreate,
    StoreDetail,
    StoreOut,
    StoreRentalRow,
    StoreSetIn,
    StoreSetOut,
    StoreTicketBrief,
    StoreUpdate,
)
from app.services import (
    asset_movement,
    asset_rules,
    audit,
    code_master,
    settings_store,
    stats,
)

router = APIRouter(prefix="/stores", tags=["stores"])

BRAND_GROUP = "STORE_BRAND"
GRIPPER_TYPES = ("전동", "비전동")
NONELECTRIC_KIND = "비전동 그리퍼"
RECENT_LIMIT = 30


def _load(db: Session, store_id: uuid.UUID) -> Store:
    store = db.scalar(
        select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
    )
    if store is None:
        raise AppError(
            "STORE_NOT_FOUND", "매장을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return store


def _asset_counts(db: Session, store_ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    """매장마다 따로 세면 목록 한 장에 쿼리가 수십 번 나간다. 한 번에 센다."""
    if not store_ids:
        return {}
    rows = db.execute(
        select(Asset.store_id, func.count(Asset.id))
        .where(Asset.store_id.in_(store_ids), Asset.deleted_at.is_(None))
        .group_by(Asset.store_id)
    ).all()
    return {sid: n for sid, n in rows}


def _ticket_counts(db: Session, store_ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    if not store_ids:
        return {}
    rows = db.execute(
        select(ServiceTicket.store_id, func.count(ServiceTicket.id))
        .where(
            ServiceTicket.store_id.in_(store_ids), ServiceTicket.deleted_at.is_(None)
        )
        .group_by(ServiceTicket.store_id)
    ).all()
    return {sid: n for sid, n in rows}


def _open_ticket_counts(
    db: Session, store_ids: list[uuid.UUID]
) -> dict[uuid.UUID, int]:
    """미종결 대응 건수. 목록·상세가 같은 숫자를 보여 주도록 한 곳에서 센다."""
    if not store_ids:
        return {}
    rows = db.execute(
        select(ServiceTicket.store_id, func.count(ServiceTicket.id))
        .where(
            ServiceTicket.store_id.in_(store_ids),
            ServiceTicket.deleted_at.is_(None),
            ServiceTicket.status.in_(OPEN_SERVICE_STATUSES),
        )
        .group_by(ServiceTicket.store_id)
    ).all()
    return {sid: n for sid, n in rows}


def _brand_map(db: Session) -> dict[uuid.UUID, CodeItem]:
    group = db.scalar(select(CodeGroup).where(CodeGroup.code == BRAND_GROUP))
    if group is None:
        return {}
    return {
        item.id: item
        for item in db.scalars(select(CodeItem).where(CodeItem.group_id == group.id))
    }


# ------------------------------------------------------------------ 브랜드


@router.get("/brands", response_model=list[BrandSummary])
def list_brands(db: DbSession, _: CurrentUser) -> list[BrandSummary]:
    """브랜드별 매장 수와 보유 자산 수. 재고·매장 화면의 첫 단계."""
    brands = _brand_map(db)

    store_rows = db.execute(
        select(
            Store.brand_id,
            func.count(Store.id),
            # 운영 중인 매장 수. case 로 세는 이유는 방언마다 boolean 의
            # 산술 취급이 달라서다(SQLite 는 0/1, PostgreSQL 은 아님).
            func.sum(case((Store.is_closed.is_(False), 1), else_=0)),
        )
        .where(Store.deleted_at.is_(None))
        .group_by(Store.brand_id)
    ).all()

    asset_rows = db.execute(
        select(Store.brand_id, func.count(Asset.id))
        .select_from(Store)
        .join(Asset, Asset.store_id == Store.id)
        .where(Store.deleted_at.is_(None), Asset.deleted_at.is_(None))
        .group_by(Store.brand_id)
    ).all()
    assets = {bid: n for bid, n in asset_rows}

    ticket_rows = db.execute(
        select(
            Store.brand_id,
            func.count(ServiceTicket.id),
            func.sum(
                case(
                    (
                        ServiceTicket.status.notin_(
                            [ServiceStatus.COMPLETED, ServiceStatus.CANCELED]
                        ),
                        1,
                    ),
                    else_=0,
                )
            ),
        )
        .join(ServiceTicket, ServiceTicket.store_id == Store.id)
        .where(Store.deleted_at.is_(None), ServiceTicket.deleted_at.is_(None))
        .group_by(Store.brand_id)
    ).all()
    ticket_counts = {bid: (total, opened) for bid, total, opened in ticket_rows}
    out: list[BrandSummary] = []
    for brand_id, total, open_count in store_rows:
        item = brands.get(brand_id) if brand_id else None
        out.append(
            BrandSummary(
                brand_id=brand_id,
                brand_name=item.name if item else "미지정",
                color=item.color if item else None,
                store_count=total,
                open_store_count=int(open_count or 0),
                asset_count=assets.get(brand_id, 0),
                ticket_count=ticket_counts.get(brand_id, (0, 0))[0],
                open_ticket_count=int(ticket_counts.get(brand_id, (0, 0))[1] or 0),
            )
        )
    # 브랜드 목록 순서(바른치킨 · 자담치킨 · 삼성 · …)대로. 목록에 없는 것은 뒤에.
    order = {
        bid: n
        for n, bid in enumerate(
            sorted(brands, key=lambda b: (brands[b].sort_order, brands[b].name))
        )
    }
    out.sort(key=lambda b: (order.get(b.brand_id, 999), b.brand_name))
    return out


# ------------------------------------------------------------------ 매장


@router.get("", response_model=Page[StoreOut])
def list_stores(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    q: str | None = Query(None, description="매장명 · 메모"),
    brand_id: uuid.UUID | None = None,
    include_closed: bool | None = Query(None, description="미운영 매장도 포함"),
    include_inactive: bool = False,
    sort: str = "name",
    descending: bool = False,
) -> Page[StoreOut]:
    stmt = select(Store).where(Store.deleted_at.is_(None))
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(Store.name.ilike(like) | Store.note.ilike(like))
    if brand_id:
        stmt = stmt.where(Store.brand_id == brand_id)
    if include_closed is None:
        include_closed = settings_store.get(
            db, ModuleKey.STORE, "show_closed_stores", False
        )
    if not include_closed:
        stmt = stmt.where(Store.is_closed.is_(False))

    if not include_inactive:
        stmt = stmt.where(Store.is_active.is_(True))
    ticket_count = (
        select(func.count(ServiceTicket.id))
        .where(ServiceTicket.store_id == Store.id, ServiceTicket.deleted_at.is_(None))
        .correlate(Store)
        .scalar_subquery()
    )
    last_ticket = (
        select(func.max(ServiceTicket.received_at))
        .where(ServiceTicket.store_id == Store.id, ServiceTicket.deleted_at.is_(None))
        .correlate(Store)
        .scalar_subquery()
    )
    sort_column = {
        "name": Store.name,
        "open_date": Store.open_date,
        "created_at": Store.created_at,
        "ticket_count": ticket_count,
        "asset_count": select(func.count(Asset.id))
        .where(Asset.store_id == Store.id, Asset.deleted_at.is_(None))
        .correlate(Store)
        .scalar_subquery(),
        "open_ticket_count": select(func.count(ServiceTicket.id))
        .where(
            ServiceTicket.store_id == Store.id,
            ServiceTicket.deleted_at.is_(None),
            ServiceTicket.status.in_(OPEN_SERVICE_STATUSES),
        )
        .correlate(Store)
        .scalar_subquery(),
        "last_ticket_at": last_ticket,
    }.get(sort)
    if sort_column is None:
        raise AppError("INVALID_SORT", "지원하지 않는 매장 정렬입니다.")
    ordering = (
        sort_column.desc().nulls_last()
        if descending
        else sort_column.asc().nulls_last()
    )
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = list(
        db.scalars(
            stmt.order_by(ordering, Store.id).offset(page.offset).limit(page.size)
        )
    )

    ids = [r.id for r in rows]
    assets = _asset_counts(db, ids)
    last_tickets = dict(
        db.execute(
            select(ServiceTicket.store_id, func.max(ServiceTicket.received_at))
            .where(ServiceTicket.store_id.in_(ids), ServiceTicket.deleted_at.is_(None))
            .group_by(ServiceTicket.store_id)
        ).all()
    )
    tickets = _ticket_counts(db, ids)
    open_tickets = _open_ticket_counts(db, ids)
    brands = _brand_map(db)

    items: list[StoreOut] = []
    for row in rows:
        out = StoreOut.model_validate(row)
        out.asset_count = assets.get(row.id, 0)
        out.ticket_count = tickets.get(row.id, 0)
        out.last_ticket_at = last_tickets.get(row.id)
        out.open_ticket_count = open_tickets.get(row.id, 0)
        item = brands.get(row.brand_id) if row.brand_id else None
        out.brand = CodeItemBrief.model_validate(item) if item else None
        items.append(out)
    return Page.build(items, total, page.page, page.size)


@router.get("/{store_id}", response_model=StoreDetail)
def get_store(store_id: uuid.UUID, db: DbSession, _: CurrentUser) -> StoreDetail:
    """매장 하나와 그 매장에 나가 있는 우리 자산 전부(종류별로 묶어서), 그리고 구 서버 매장
    화면이 보여 주던 것들: 서비스구분별 발생, 미회수 렌탈, 대응 이력, 미운영 회수 안내."""
    store = _load(db, store_id)
    return _detail(db, store)


def _detail(db: Session, store: Store) -> StoreDetail:
    out = StoreDetail.model_validate(store)

    brands = _brand_map(db)
    item = brands.get(store.brand_id) if store.brand_id else None
    out.brand = CodeItemBrief.model_validate(item) if item else None
    brand_name = item.name if item else None

    assets = list(
        db.scalars(
            select(Asset)
            .where(Asset.store_id == store.id, Asset.deleted_at.is_(None))
            .order_by(Asset.set_no, Asset.name, Asset.serial_no)
        )
    )
    used_sets = {a.set_no for a in assets if a.set_no}
    set_rows = {
        s.set_no: s
        for s in db.scalars(
            select(StoreSet)
            .where(StoreSet.store_id == store.id)
            .order_by(StoreSet.set_no)
        )
    }
    out.sets = [StoreSetOut.model_validate(set_rows[n]) for n in sorted(set_rows)]
    for n in sorted(used_sets - set(set_rows)):  # 장비에만 쓰인 세트 번호도 목록에
        out.sets.append(
            StoreSetOut(
                id=uuid.uuid5(uuid.NAMESPACE_URL, f"{store.id}/{n}"),
                set_no=n,
                name=None,
            )
        )
    out.sets.sort(key=lambda s: s.set_no)

    out.asset_count = len(assets)
    out.ticket_count = _ticket_counts(db, [store.id]).get(store.id, 0)
    out.open_ticket_count = _open_ticket_counts(db, [store.id]).get(store.id, 0)
    dates = [a.purchase_date for a in assets if a.purchase_date]
    out.install_date = min(dates) if dates else None

    # 종류 이름·색은 코드 마스터에서 한 번에 끌어온다.
    code_ids = {a.category_id for a in assets if a.category_id}
    code_ids |= {a.status_item_id for a in assets if a.status_item_id}
    codes = (
        {c.id: c for c in db.scalars(select(CodeItem).where(CodeItem.id.in_(code_ids)))}
        if code_ids
        else {}
    )

    _detail_asset_groups(db, assets, codes, out)

    _detail_categories(db, store, out)
    _detail_rentals(db, store, out)
    _detail_recent(db, store, out)

    out.recover_options = [
        CodeItemBrief.model_validate(i)
        for i in asset_rules.recover_options(db, brand_name)
    ]
    movable, rented = 0, 0
    for a in assets:
        si = codes.get(a.status_item_id) if a.status_item_id else None
        if asset_rules.is_movable_on_close(si):
            movable += 1
        elif si is not None and asset_rules.rule_of(si).enum == AssetStatus.LOANED:
            rented += 1
    out.movable_count, out.rental_count = movable, rented
    return out


def _detail_asset_groups(db, assets, codes, out):
    kinds = {k.id: n for n, k in enumerate(_kind_items(db))}
    groups: dict[uuid.UUID | None, StoreAssetGroup] = {}
    for asset in assets:
        cat = codes.get(asset.category_id) if asset.category_id else None
        key = asset.category_id
        if key not in groups:
            groups[key] = StoreAssetGroup(
                category_id=key,
                category_name=cat.name if cat else "미분류",
                color=cat.color if cat else None,
                count=0,
                assets=[],
            )
        status_item = codes.get(asset.status_item_id) if asset.status_item_id else None
        groups[key].assets.append(
            AssetInStore(
                id=asset.id,
                asset_no=asset.asset_no,
                name=asset.name,
                category=CodeItemBrief.model_validate(cat) if cat else None,
                model_name=asset.model_name,
                serial_no=asset.serial_no,
                status=asset.status.value,
                status_item=CodeItemBrief.model_validate(status_item)
                if status_item
                else None,
                set_no=asset.set_no,
            )
        )
        groups[key].count += 1
    out.asset_groups = sorted(
        groups.values(), key=lambda g: (kinds.get(g.category_id, 99), g.category_name)
    )


def _detail_categories(db, store, out):
    # 서비스구분별 발생 (원인 행 수, 구 서버 매장 화면의 막대)
    cat_rows = db.execute(
        select(ServiceTicketCause.category_id, func.count(ServiceTicketCause.id))
        .select_from(ServiceTicketCause)
        .join(ServiceTicket, ServiceTicket.id == ServiceTicketCause.ticket_id)
        .where(ServiceTicket.store_id == store.id, ServiceTicket.deleted_at.is_(None))
        .group_by(ServiceTicketCause.category_id)
    ).all()
    counts = {cid: n for cid, n in cat_rows}
    out.category_counts = [
        CategoryCount(
            category_id=c.id, label=c.name, color=c.color, count=counts.get(c.id, 0)
        )
        for c in _code_items(db, "SERVICE_CATEGORY")
    ]
    if counts.get(None):
        out.category_counts.append(
            CategoryCount(category_id=None, label="미분류", count=counts[None])
        )


def _detail_rentals(db, store, out):
    today = datetime.now(stats.LOCAL_TZ).date()
    rentals = db.scalars(
        select(ServiceTicket)
        .where(
            ServiceTicket.store_id == store.id,
            ServiceTicket.deleted_at.is_(None),
            ServiceTicket.is_rental.is_(True),
            ServiceTicket.rental_returned.is_(False),
        )
        .order_by(ServiceTicket.rental_due_date.asc().nulls_last())
    ).all()
    type_ids = {t.rental_type_id for t in rentals if t.rental_type_id}
    types = (
        {
            c.id: c.name
            for c in db.scalars(select(CodeItem).where(CodeItem.id.in_(type_ids)))
        }
        if type_ids
        else {}
    )
    out.unreturned_rentals = [
        StoreRentalRow(
            ticket_id=t.id,
            ticket_no=t.ticket_no,
            rental_type=types.get(t.rental_type_id),
            serials=t.rental_serials,
            due_date=t.rental_due_date,
            dday=(t.rental_due_date - today).days if t.rental_due_date else None,
        )
        for t in rentals
    ]


def _detail_recent(db, store, out):
    recent = db.scalars(
        select(ServiceTicket)
        .where(ServiceTicket.store_id == store.id, ServiceTicket.deleted_at.is_(None))
        .order_by(ServiceTicket.received_at.desc(), ServiceTicket.created_at.desc())
        .limit(RECENT_LIMIT)
    ).all()
    from app.services.ticket_view import (
        _extras,  # 목록 곁 정보(원인 라벨)를 같은 코드로
    )

    extras = _extras(db, list(recent))
    from app.services.ticket_view import _cause_label

    out.recent_tickets = [
        StoreTicketBrief(
            id=t.id,
            ticket_no=t.ticket_no,
            title=t.title,
            status=t.status.value,
            received_at=t.received_at,
            completed_at=t.completed_at,
            cause_labels=[_cause_label(c) for c in extras[t.id]["causes"]],
        )
        for t in recent
    ]

    out.last_ticket_at = recent[0].received_at if recent else None


@router.post("", response_model=StoreDetail, status_code=status.HTTP_201_CREATED)
def create_store(
    payload: StoreCreate, db: DbSession, user: AdminUser, client: Client
) -> StoreDetail:
    if db.scalar(
        select(Store.id).where(Store.name == payload.name, Store.deleted_at.is_(None))
    ):
        raise AppError(
            "STORE_NAME_TAKEN",
            "같은 이름의 매장이 이미 있습니다.",
            status.HTTP_409_CONFLICT,
        )
    data = payload.model_dump()
    if not data.get("gripper_type"):
        data["gripper_type"] = settings_store.get(
            db, ModuleKey.STORE, "default_gripper_type", "전동"
        )
    store = Store(**data, created_by_id=user.id)
    db.add(store)
    db.flush()
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.STORE,
        entity_type="store",
        entity_id=store.id,
        summary=f"매장 등록 {store.name}",
        client=client,
    )
    db.commit()
    return get_store(store.id, db, user)


@router.patch("/{store_id}", response_model=StoreDetail)
def update_store(
    store_id: uuid.UUID,
    payload: StoreUpdate,
    db: DbSession,
    user: AdminUser,
    client: Client,
) -> StoreDetail:
    store = _load(db, store_id)
    data = payload.model_dump(exclude_unset=True)
    recover_to = data.pop("recover_to_status_item_id", None)
    if (
        "name" in data
        and data["name"] != store.name
        and db.scalar(
            select(Store.id).where(
                Store.name == data["name"],
                Store.deleted_at.is_(None),
                Store.id != store.id,
            )
        )
    ):
        raise AppError(
            "STORE_NAME_TAKEN",
            "같은 이름의 매장이 이미 있습니다.",
            status.HTTP_409_CONFLICT,
        )
    if data.get("closed_date") and "is_closed" not in data:
        data["is_closed"] = True  # 미운영일을 넣으면 미운영으로 본다 (구 서버와 같음)
    if data.get("is_closed") is False:
        data["closed_date"] = None
    before = {k: getattr(store, k) for k in data}
    for field, value in data.items():
        setattr(store, field, value)
    store.updated_by_id = user.id

    moved: list[str] = []
    notices = []
    if (
        data.get("is_closed")
        and not before.get("is_closed", False)
        or (data.get("is_closed") and recover_to)
    ):
        moved, notices = _recover_closed_store_assets(db, store, recover_to, user)

    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.STORE,
        entity_type="store",
        entity_id=store.id,
        summary=f"매장 수정 {store.name}"
        + (f" · 미운영 회수 {len(moved)}대" if moved else ""),
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    out = get_store(store_id, db, user)
    out.notices = notices
    return out


@router.post("/{store_id}/close", response_model=StoreCloseResult)
def close_store(
    store_id: uuid.UUID,
    payload: StoreCloseRequest,
    db: DbSession,
    user: AdminUser,
    client: Client,
) -> StoreCloseResult:
    """미운영 처리 (구 서버 매장 화면의 [매장 상태 저장]): 설치 · AS 장비를 고른 회수 위치로.

    렌탈 중 장비는 건드리지 않는다 - 대응 기록에서 회수 처리하면 창고로 돌아온다.
    그 매장 장비 전부를 옮기는 대량 변경이라 관리자(ADMIN) 이상만. `PATCH is_closed` 는
    ADMIN 이므로 이 경로가 우회로가 되지 않게 한다.
    """
    store = _load(db, store_id)
    store.is_closed = True
    store.closed_date = payload.closed_date or store.closed_date
    if payload.note is not None:
        store.note = payload.note
    store.updated_by_id = user.id
    moved, notices = _recover_closed_store_assets(
        db, store, payload.recover_to_status_item_id, user
    )
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.STORE,
        entity_type="store",
        entity_id=store.id,
        summary=f"매장 미운영 {store.name} · 장비 {len(moved)}대 회수",
        client=client,
    )
    db.commit()
    return StoreCloseResult(
        store=_detail(db, _load(db, store_id)), moved=moved, notices=notices
    )


def _recover_closed_store_assets(
    db: Session, store: Store, target_id: uuid.UUID | None, user: User
) -> tuple[list[str], list[str]]:
    """미운영 매장의 설치 · AS 장비를 target(회수 상태)로. 돌려주는 값: (옮긴 장비, 안내)."""
    brands = _brand_map(db)
    brand_name = brands[store.brand_id].name if store.brand_id in brands else None
    options = {i.id: i for i in asset_rules.recover_options(db, brand_name)}
    target = options.get(target_id) if target_id else None
    if target_id and target is None:
        target = asset_rules.load_status_item(db, target_id)
        if asset_rules.rule_of(target).kind in ("store", "as"):
            raise AppError(
                "BAD_RECOVER_TARGET",
                f'"{target.name}"은(는) 회수 위치로 쓸 수 없습니다.',
            )

    assets = list(
        db.scalars(
            select(Asset).where(Asset.store_id == store.id, Asset.deleted_at.is_(None))
        ).all()
    )
    status_of = {
        a.id: (db.get(CodeItem, a.status_item_id) if a.status_item_id else None)
        for a in assets
    }
    installed = [a for a in assets if asset_rules.is_movable_on_close(status_of[a.id])]
    rented = [
        a
        for a in assets
        if (si := status_of[a.id]) is not None
        and asset_rules.rule_of(si).enum == AssetStatus.LOANED
    ]
    moved: list[str] = []
    notices: list[str] = []
    kinds = {k.id: k.name for k in _kind_items(db)}

    if target is not None and installed:
        for a in installed:
            movement = asset_movement.begin(
                a,
                movement_type=MovementType.RETURN,
                quantity=a.quantity,
                moved_at=now_utc(),
                moved_by_id=user.id,
                reason=f"매장 미운영 ({store.name}) → {target.name}",
            )
            a.store_id = None
            asset_rules.apply_status(db, a, target)
            a.updated_by_id = user.id
            asset_movement.finish(movement, a)
            db.add(movement)
            moved.append(
                f"{kinds.get(a.category_id, a.name)} {a.serial_no or a.asset_no}"
            )
        notices.append(
            f'이 매장의 설치 장비 {len(installed)}대를 "{target.name}"(으)로 옮겼습니다.'
        )
    elif installed:
        notices.append(
            f"이 매장에 설치 장비 {len(installed)}대가 남아 있습니다. 회수 위치를 고르지 않아 재고는 바꾸지 않았습니다 "
            "([재고]에서 직접 옮기거나 회수 위치를 골라 다시 저장)."
        )
    if rented:
        notices.append(
            f"이 매장에 렌탈 중인 장비 {len(rented)}대가 있습니다. 대응 기록에서 회수 처리하면 재고가 창고로 돌아옵니다."
        )
    return moved, notices


@router.delete("/{store_id}", response_model=Message)
def delete_store(
    store_id: uuid.UUID, db: DbSession, user: AdminUser, client: Client
) -> Message:
    store = _load(db, store_id)
    held = db.scalar(
        select(func.count(Asset.id)).where(
            Asset.store_id == store.id, Asset.deleted_at.is_(None)
        )
    )
    if held:
        raise AppError(
            "STORE_HAS_ASSETS",
            f"이 매장에 자산 {held}대가 남아 있습니다. 먼저 회수하거나 옮겨 주세요.",
            status.HTTP_409_CONFLICT,
            {"asset_count": held},
        )
    tickets = _ticket_counts(db, [store.id]).get(store.id, 0)
    if tickets:
        raise AppError(
            "STORE_HAS_TICKETS",
            "대응 이력이 있는 매장은 삭제할 수 없습니다. 비활성화해 주세요.",
            409,
        )
    store.deleted_at = now_utc()
    from app.services.attachment_lifecycle import soft_delete

    soft_delete(db, "store", store.id)
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=user,
        module=ModuleKey.STORE,
        entity_type="store",
        entity_id=store.id,
        summary=f"매장 삭제 {store.name}",
        client=client,
    )
    db.commit()
    return Message(message="매장을 삭제했습니다.")


# ------------------------------------------------------------------ 납품 세트


@router.post(
    "/{store_id}/sets", response_model=StoreDetail, status_code=status.HTTP_201_CREATED
)
def add_set(
    store_id: uuid.UUID, payload: StoreSetIn, db: DbSession, user: AdminUser
) -> StoreDetail:
    store = _load(db, store_id)
    used = {
        n
        for (n,) in db.execute(
            select(StoreSet.set_no).where(StoreSet.store_id == store.id)
        ).all()
    }
    used |= {
        n
        for (n,) in db.execute(
            select(Asset.set_no).where(Asset.store_id == store.id, Asset.set_no > 0)
        ).all()
    }
    no = (max(used) if used else 0) + 1
    db.add(
        StoreSet(
            store_id=store.id, set_no=no, name=(payload.name or "").strip() or None
        )
    )
    db.commit()
    return _detail(db, store)


@router.patch("/{store_id}/sets/{set_no}", response_model=StoreDetail)
def rename_set(
    store_id: uuid.UUID,
    set_no: int,
    payload: StoreSetIn,
    db: DbSession,
    user: AdminUser,
) -> StoreDetail:
    store = _load(db, store_id)
    if set_no < 1:
        raise AppError("BAD_SET_NO", "세트 번호는 1 이상입니다.")
    row = db.scalar(
        select(StoreSet).where(StoreSet.store_id == store.id, StoreSet.set_no == set_no)
    )
    if row is None:
        row = StoreSet(store_id=store.id, set_no=set_no)
        db.add(row)
    row.name = (payload.name or "").strip() or None
    db.commit()
    return _detail(db, store)


@router.delete("/{store_id}/sets/{set_no}", response_model=StoreDetail)
def delete_set(
    store_id: uuid.UUID, set_no: int, db: DbSession, user: AdminUser
) -> StoreDetail:
    store = _load(db, store_id)
    n_in = (
        db.scalar(
            select(func.count(Asset.id)).where(
                Asset.store_id == store.id,
                Asset.set_no == set_no,
                Asset.deleted_at.is_(None),
            )
        )
        or 0
    )
    if n_in:
        raise AppError(
            "SET_NOT_EMPTY",
            f"세트 {set_no}에 장비 {n_in}대가 있어 지울 수 없습니다. 장비를 다른 세트로 옮긴 뒤 지우세요.",
        )
    row = db.scalar(
        select(StoreSet).where(StoreSet.store_id == store.id, StoreSet.set_no == set_no)
    )
    if row is not None:
        db.delete(row)
    db.commit()
    return _detail(db, store)


# ------------------------------------------------------------------ 매장 장비 설정 (구 서버 store_equipment)


@router.post("/{store_id}/equipment", response_model=EquipmentSetupResult)
def setup_equipment(
    store_id: uuid.UUID,
    payload: EquipmentSetupRequest,
    db: DbSession,
    user: AdminUser,
    client: Client,
) -> EquipmentSetupResult:
    """납품 장비 세트를 한 화면에서 저장. 없는 S/N 은 등록, 다른 곳의 장비는 이 매장으로,
    이미 있으면 세트만 맞춘다. 비전동 세트에 S/N 없는 비전동 그리퍼는 관리 번호를 붙인다."""
    store = _load(db, store_id)
    for i, s in enumerate(payload.sets, 1):
        if s.gripper_type not in GRIPPER_TYPES:
            raise AppError(
                "BAD_GRIPPER_TYPE",
                f"{i}번째 세트의 그리퍼 종류(전동/비전동)를 고르세요.",
            )
    installed_item = asset_rules.find_status_item(
        db, "설치"
    ) or asset_rules.find_status_item_by_rule(db, "store", AssetStatus.IN_USE)
    if installed_item is None:
        raise AppError(
            "STATUS_MISSING",
            "재고 상태 목록에 '설치'가 없습니다. [관리]→[분류 코드]에서 추가하세요.",
        )

    kinds = {k.id: k for k in _kind_items(db)}
    ne_kind = next((k for k in kinds.values() if k.name == NONELECTRIC_KIND), None)

    _validate_equipment_serials(db, payload, kinds)
    prefix = (
        settings_store.get(db, ModuleKey.INVENTORY, "nonelectric_serial_prefix", "NG-")
        or "NG-"
    )
    # 이미 이 매장에 설치된 비전동 그리퍼 수만큼은 새 관리 번호를 만들지 않는다 (다시 저장해도 중복 안 생기게)
    ng_have = (
        db.scalar(
            select(func.count(Asset.id)).where(
                Asset.store_id == store.id,
                Asset.deleted_at.is_(None),
                Asset.category_id == (ne_kind.id if ne_kind else None),
            )
        )
        or 0
        if ne_kind
        else 0
    )

    added: list[str] = []
    moved: list[str] = []
    kept: list[str] = []
    set_names = {
        r.set_no: r
        for r in db.scalars(select(StoreSet).where(StoreSet.store_id == store.id)).all()
    }

    for idx, s in enumerate(payload.sets, 1):
        n = s.set_no or idx
        row = set_names.get(n)
        if row is None:
            row = StoreSet(store_id=store.id, set_no=n)
            db.add(row)
            set_names[n] = row
        if s.name is not None:
            row.name = s.name.strip() or None

        slots = list(s.slots)
        if s.gripper_type == "비전동" and ne_kind is not None:
            has_ne_serial = any(
                sl.category_id == ne_kind.id and (sl.serial_no or "").strip()
                for sl in slots
            )
            if not has_ne_serial:
                if ng_have > 0:
                    ng_have -= 1
                else:
                    serial = asset_rules.next_managed_serial(db, ne_kind.id, prefix)
                    model = next(
                        (
                            sl.model_name
                            for sl in slots
                            if sl.category_id == ne_kind.id and sl.model_name
                        ),
                        None,
                    )
                    asset = _new_installed_asset(
                        db,
                        store,
                        ne_kind,
                        serial,
                        model,
                        None,
                        payload,
                        n,
                        user,
                        note=s.note or "관리 번호 자동 부여",
                    )
                    asset_rules.apply_status(db, asset, installed_item)
                    _record(
                        db,
                        asset,
                        user,
                        MovementType.INBOUND,
                        f"설치 {store.name} (매장 장비 설정, 관리 번호 자동)",
                    )
                    added.append(f"{ne_kind.name} {serial}")
            slots = [
                sl
                for sl in slots
                if sl.category_id != ne_kind.id or (sl.serial_no or "").strip()
            ]
        _place_equipment_slots(
            db,
            store,
            payload,
            user,
            kinds,
            installed_item,
            slots,
            n,
            s.note,
            added,
            moved,
            kept,
        )

    store.gripper_type = payload.sets[0].gripper_type
    store.updated_by_id = user.id
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.STORE,
        entity_type="store",
        entity_id=store.id,
        summary=f"매장 장비 설정 {store.name}: 등록 {len(added)} · 이동 {len(moved)} · 유지 {len(kept)}",
        client=client,
    )
    db.commit()
    return EquipmentSetupResult(
        added=added, moved=moved, kept=kept, store=_detail(db, _load(db, store_id))
    )


def _validate_equipment_serials(db, payload, kinds):
    # 재고에 등록되지 않은 S/N 은 매장에 붙일 수 없다 (설정 equipment_requires_known_serial).
    # 장비는 [장비 목록]에서 먼저 등록하고, 여기서는 어느 매장·세트에 두는지만 정한다.
    # 한 칸이라도 모르는 S/N 이 있으면 아무것도 저장하지 않고 전부 알려 준다.
    if settings_store.get(db, ModuleKey.STORE, "equipment_requires_known_serial", True):
        unknown: list[str] = []
        for s in payload.sets:
            for sl in s.slots:
                serial = asset_rules.normalise_serial(sl.serial_no)
                kind = kinds.get(sl.category_id)
                if (
                    serial
                    and kind is not None
                    and asset_rules.find_asset_by_serial(db, serial, kind.id) is None
                ):
                    unknown.append(f"{kind.name} {serial}")
        if unknown:
            raise AppError(
                "SERIAL_UNKNOWN",
                "재고에 등록되지 않은 S/N 입니다: "
                + ", ".join(unknown)
                + ". [장비 목록]에서 먼저 등록한 뒤 매장에 배치하세요.",
                details={"unknown": unknown},
            )


def _place_equipment_slots(
    db, store, payload, user, kinds, installed_item, slots, n, note, added, moved, kept
):
    for sl in slots:
        serial = asset_rules.normalise_serial(sl.serial_no)
        if not serial:
            continue
        kind = kinds.get(sl.category_id)
        if kind is None:
            raise AppError("BAD_KIND", "장비 종류가 목록에 없습니다.")
        tag = f" ({n}번째 세트)" if len(payload.sets) > 1 else ""
        asset = asset_rules.find_asset_by_serial(db, serial, kind.id)
        if asset is None:
            asset = _new_installed_asset(
                db,
                store,
                kind,
                serial,
                sl.model_name,
                sl.manufacturer,
                payload,
                n,
                user,
                note=note,
            )
            asset_rules.apply_status(db, asset, installed_item)
            _record(
                db,
                asset,
                user,
                MovementType.INBOUND,
                f"설치 {store.name} (매장 장비 설정)",
            )
            added.append(f"{kind.name} {serial}{tag}")
        elif asset.store_id == store.id and asset_rules.is_at_store_rule(
            db.get(CodeItem, asset.status_item_id) if asset.status_item_id else None
        ):
            if asset.set_no != n:
                asset.set_no = n
                asset.updated_by_id = user.id
            kept.append(f"{kind.name} {serial}")
        else:
            before = _place_label(db, asset)
            movement = asset_movement.begin(
                asset,
                movement_type=MovementType.MOVE,
                quantity=asset.quantity,
                moved_at=now_utc(),
                moved_by_id=user.id,
                reason=f"{before} → 설치 {store.name} 세트 {n} (매장 장비 설정)",
            )
            asset.store_id = store.id
            asset.set_no = n
            if payload.install_date:
                asset.purchase_date = payload.install_date
            asset_rules.apply_status(db, asset, installed_item)
            asset.updated_by_id = user.id
            asset_movement.finish(movement, asset)
            db.add(movement)
            moved.append(f"{kind.name} {serial} ({before}에서){tag}")


def _new_installed_asset(
    db, store, kind, serial, model, manufacturer, payload, set_no, user, note=None
) -> Asset:
    from app.api.v1.inventory import _insert_asset

    if not manufacturer:
        maker = _first_child(db, "ASSET_MAKER", kind.id)
        manufacturer = maker.name if maker else None
    if not model:
        m = _first_child(db, "ASSET_MODEL", kind.id)
        model = m.name if m else None
    asset = Asset(
        name=f"{kind.name} {model or ''}".strip(),
        category_id=kind.id,
        model_name=model,
        manufacturer=manufacturer,
        serial_no=serial,
        store_id=store.id,
        set_no=set_no,
        purchase_date=payload.install_date,
        note=note or None,
        created_by_id=user.id,
    )
    _insert_asset(db, asset, None)
    return asset


def _record(db, asset, user, mtype, reason) -> None:
    db.add(
        asset_movement.inbound(
            asset,
            movement_type=mtype,
            quantity=asset.quantity,
            moved_at=now_utc(),
            moved_by_id=user.id,
            reason=reason,
        )
    )


def _place_label(db, asset) -> str:
    st = (
        db.get(CodeItem, asset.status_item_id).name
        if asset.status_item_id
        else asset.status.value
    )
    if asset.store_id:
        s = db.get(Store, asset.store_id)
        return f"{st} {s.name if s else ''}".strip()
    if asset.location_id:
        from app.models.inventory import Location

        loc = db.get(Location, asset.location_id)
        return f"{st} {loc.name if loc else ''}".strip()
    return st


def _kind_items(db: Session) -> list[CodeItem]:
    return _code_items(db, asset_rules.CATEGORY_GROUP)


def _code_items(db: Session, group_code: str) -> list[CodeItem]:
    return code_master.items(db, group_code)


def _first_child(db: Session, group_code: str, parent_id: uuid.UUID) -> CodeItem | None:
    group = db.scalar(select(CodeGroup).where(CodeGroup.code == group_code))
    if group is None:
        return None
    return db.scalar(
        select(CodeItem)
        .where(
            CodeItem.group_id == group.id,
            CodeItem.parent_id == parent_id,
            CodeItem.deleted_at.is_(None),
            CodeItem.is_active.is_(True),
        )
        .order_by(CodeItem.sort_order)
        .limit(1)
    )
