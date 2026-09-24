"""매장 module.

무엇이 어느 매장에 나가 있는지가 이 모듈의 존재 이유다. 재고(`/inventory`)는
"우리가 가진 것"을 창고 기준으로 보고, 여기는 같은 자산을 고객 사이트 기준으로
본다. 두 화면이 같은 `assets` 행을 다른 축으로 읽는다.

브랜드는 분류 코드(CodeGroup "STORE_BRAND")다. 바른치킨·자담치킨처럼 매장이
묶이는 단위이고, 이름이 바뀌어도 FK 라 매장 쪽이 따라온다.
"""
from __future__ import annotations

import uuid

from fastapi import APIRouter, Query, status
from sqlalchemy import case, func, select
from sqlalchemy.orm import Session

from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import AuditAction, ModuleKey
from app.models.inventory import Asset
from app.models.service import ServiceTicket
from app.models.store import Store, StoreSet
from app.schemas.common import CodeItemBrief, Message, Page
from app.schemas.store import (
    AssetInStore,
    BrandSummary,
    StoreAssetGroup,
    StoreCreate,
    StoreDetail,
    StoreOut,
    StoreSetOut,
    StoreUpdate,
)
from app.services import audit

router = APIRouter(prefix="/stores", tags=["stores"])

BRAND_GROUP = "STORE_BRAND"


def _load(db: Session, store_id: uuid.UUID) -> Store:
    store = db.scalar(
        select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
    )
    if store is None:
        raise AppError("STORE_NOT_FOUND", "매장을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
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
        .where(ServiceTicket.store_id.in_(store_ids), ServiceTicket.deleted_at.is_(None))
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
            )
        )
    out.sort(key=lambda b: (-b.store_count, b.brand_name))
    return out


# ------------------------------------------------------------------ 매장


@router.get("", response_model=Page[StoreOut])
def list_stores(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    q: str | None = Query(None, description="매장명"),
    brand_id: uuid.UUID | None = None,
    include_closed: bool = Query(False, description="폐점 매장도 포함"),
) -> Page[StoreOut]:
    stmt = select(Store).where(Store.deleted_at.is_(None))
    if q:
        stmt = stmt.where(Store.name.ilike(f"%{q.strip()}%"))
    if brand_id:
        stmt = stmt.where(Store.brand_id == brand_id)
    if not include_closed:
        stmt = stmt.where(Store.is_closed.is_(False))

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = list(
        db.scalars(stmt.order_by(Store.name).offset(page.offset).limit(page.size))
    )

    ids = [r.id for r in rows]
    assets = _asset_counts(db, ids)
    tickets = _ticket_counts(db, ids)
    brands = _brand_map(db)

    items: list[StoreOut] = []
    for row in rows:
        out = StoreOut.model_validate(row)
        out.asset_count = assets.get(row.id, 0)
        out.ticket_count = tickets.get(row.id, 0)
        item = brands.get(row.brand_id) if row.brand_id else None
        out.brand = CodeItemBrief.model_validate(item) if item else None
        items.append(out)
    return Page.build(items, total, page.page, page.size)


@router.get("/{store_id}", response_model=StoreDetail)
def get_store(store_id: uuid.UUID, db: DbSession, _: CurrentUser) -> StoreDetail:
    """매장 하나와 그 매장에 나가 있는 우리 자산 전부(종류별로 묶어서)."""
    store = _load(db, store_id)
    out = StoreDetail.model_validate(store)

    brands = _brand_map(db)
    item = brands.get(store.brand_id) if store.brand_id else None
    out.brand = CodeItemBrief.model_validate(item) if item else None

    out.sets = [
        StoreSetOut.model_validate(s)
        for s in db.scalars(
            select(StoreSet).where(StoreSet.store_id == store.id).order_by(StoreSet.set_no)
        )
    ]

    assets = list(
        db.scalars(
            select(Asset)
            .where(Asset.store_id == store.id, Asset.deleted_at.is_(None))
            .order_by(Asset.set_no, Asset.name, Asset.serial_no)
        )
    )
    out.asset_count = len(assets)
    out.ticket_count = _ticket_counts(db, [store.id]).get(store.id, 0)

    # 종류 이름·색은 코드 마스터에서 한 번에 끌어온다.
    code_ids = {a.category_id for a in assets if a.category_id}
    code_ids |= {a.status_item_id for a in assets if a.status_item_id}
    codes = {
        c.id: c
        for c in db.scalars(select(CodeItem).where(CodeItem.id.in_(code_ids)))
    } if code_ids else {}

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
                status_item=CodeItemBrief.model_validate(status_item) if status_item else None,
                set_no=asset.set_no,
            )
        )
        groups[key].count += 1

    out.asset_groups = sorted(groups.values(), key=lambda g: (-g.count, g.category_name))
    return out


@router.post("", response_model=StoreDetail, status_code=status.HTTP_201_CREATED)
def create_store(
    payload: StoreCreate, db: DbSession, user: AdminUser, client: Client
) -> StoreDetail:
    if db.scalar(
        select(Store.id).where(Store.name == payload.name, Store.deleted_at.is_(None))
    ):
        raise AppError("STORE_NAME_TAKEN", "같은 이름의 매장이 이미 있습니다.", status.HTTP_409_CONFLICT)

    store = Store(**payload.model_dump(), created_by_id=user.id)
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
    before = {k: getattr(store, k) for k in data}
    for field, value in data.items():
        setattr(store, field, value)
    store.updated_by_id = user.id

    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.STORE,
        entity_type="store",
        entity_id=store.id,
        summary=f"매장 수정 {store.name}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    return get_store(store_id, db, user)


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
    store.deleted_at = func.now()
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
