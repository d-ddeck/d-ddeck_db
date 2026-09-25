"""재고관리 module: locations, assets, and the movement history that tracks
where each unit actually is.

구 서버(CS_Record)의 재고 규칙이 여기 붙어 있다 (app/services/asset_rules.py):
  * 세부 상태(설치 · 렌탈 중 · AS 대기 · 창고 …)가 매장/위치를 결정한다.
    설치·렌탈 중은 매장 필수, 창고·사무실·미상은 매장을 자동으로 비운다.
  * 같은 종류 안에서 S/N 은 하나. 로봇팔·제어박스·전동 그리퍼는 제조사 필수.
  * 여러 대 한 번에 등록 / 한 번에 이동. 현황(상태×종류 · 브랜드×종류 · 장소×종류) · 엑셀.
"""
from __future__ import annotations

import re
import uuid
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Annotated, Literal

from fastapi import APIRouter, Query, status
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.deps import (
    Client,
    CurrentUser,
    DbSession,
    ManagerUser,
    PageParams,
)
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import (
    AssetStatus,
    AuditAction,
    ModuleKey,
    MovementType,
)
from app.models.inventory import Asset, AssetMovement, Location
from app.models.service import ServiceTicket
from app.models.store import Store
from app.models.user import User
from app.schemas.common import CodeItemBrief, Message, Page, UserBrief
from app.schemas.inventory import (
    AssetBulkCreate,
    AssetBulkMoveRequest,
    AssetCreate,
    AssetDetail,
    AssetMoveRequest,
    AssetMovementOut,
    AssetOut,
    AssetUpdate,
    AttentionAsset,
    BulkCreateResult,
    BulkMoveResult,
    CountBucket,
    InventoryOverview,
    InventorySummary,
    LocationCreate,
    LocationNode,
    LocationOut,
    LocationUpdate,
    OverviewRow,
    RentalAsset,
    StoreBrief,
)
from app.services import asset_rules, audit, excel, settings_store, stats
from app.services.ticket_rules import split_serials

router = APIRouter(prefix="/inventory", tags=["inventory"])

DEFAULT_MAKER_CATEGORIES = ["로봇팔", "제어박스", "전동 그리퍼"]


# ================================================================== locations
@router.get("/locations", response_model=list[LocationOut])
def list_locations(
    db: DbSession, _: CurrentUser, include_inactive: bool = False
) -> list[LocationOut]:
    stmt = select(Location).where(Location.deleted_at.is_(None))
    if not include_inactive:
        stmt = stmt.where(Location.is_active.is_(True))
    rows = db.scalars(stmt.order_by(Location.sort_order, Location.name)).all()
    return [LocationOut.model_validate(r) for r in rows]


@router.get("/locations/tree", response_model=list[LocationNode])
def location_tree(db: DbSession, _: CurrentUser) -> list[LocationNode]:
    """Whole tree in one call with per-node asset counts, for the picker UI."""
    rows = db.scalars(
        select(Location)
        .where(Location.deleted_at.is_(None))
        .order_by(Location.sort_order, Location.name)
    ).all()
    counts = dict(
        db.execute(
            select(Asset.location_id, func.count(Asset.id))
            .where(Asset.deleted_at.is_(None))
            .group_by(Asset.location_id)
        ).all()
    )

    nodes = {
        r.id: LocationNode(**LocationOut.model_validate(r).model_dump(), asset_count=counts.get(r.id, 0))
        for r in rows
    }
    roots: list[LocationNode] = []
    for r in rows:
        node = nodes[r.id]
        parent = nodes.get(r.parent_id) if r.parent_id else None
        (parent.children if parent else roots).append(node)
    return roots


@router.post("/locations", response_model=LocationOut, status_code=status.HTTP_201_CREATED)
def create_location(
    payload: LocationCreate, db: DbSession, manager: ManagerUser, client: Client
) -> LocationOut:
    if db.scalar(select(Location.id).where(Location.code == payload.code)):
        raise AppError("CODE_TAKEN", "이미 사용 중인 위치 코드입니다.", status.HTTP_409_CONFLICT)
    location = Location(**payload.model_dump())
    location.path = _build_path(db, location.parent_id, location.name)
    db.add(location)
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=manager,
        module=ModuleKey.INVENTORY,
        entity_type="location",
        summary=f"위치 등록: {location.path}",
        client=client,
    )
    db.commit()
    db.refresh(location)
    return LocationOut.model_validate(location)


@router.patch("/locations/{location_id}", response_model=LocationOut)
def update_location(
    location_id: uuid.UUID, payload: LocationUpdate, db: DbSession, _: ManagerUser
) -> LocationOut:
    location = db.scalar(
        select(Location).where(Location.id == location_id, Location.deleted_at.is_(None))
    )
    if location is None:
        raise AppError("NOT_FOUND", "위치를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)

    data = payload.model_dump(exclude_unset=True)
    if data.get("parent_id") == location.id:
        raise AppError("INVALID_PARENT", "자기 자신을 상위 위치로 지정할 수 없습니다.")
    for field, value in data.items():
        setattr(location, field, value)

    if {"parent_id", "name"} & data.keys():
        location.path = _build_path(db, location.parent_id, location.name)
        _refresh_descendant_paths(db, location)
    db.commit()
    db.refresh(location)
    return LocationOut.model_validate(location)


@router.delete("/locations/{location_id}", response_model=Message)
def delete_location(location_id: uuid.UUID, db: DbSession, _: ManagerUser) -> Message:
    location = db.scalar(select(Location).where(Location.id == location_id))
    if location is None:
        raise AppError("NOT_FOUND", "위치를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    in_use = db.scalar(
        select(func.count(Asset.id)).where(
            Asset.location_id == location_id, Asset.deleted_at.is_(None)
        )
    )
    if in_use:
        raise AppError(
            "LOCATION_IN_USE", f"해당 위치에 자산 {in_use}건이 있어 삭제할 수 없습니다."
        )
    location.deleted_at = now_utc()
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== assets


# ================================================================== assets
AssetSort = Literal["created_desc", "serial_asc", "kind_serial", "updated_desc"]


def _asset_query(
    db: Session,
    *,
    q: str | None = None,
    asset_status: AssetStatus | None = None,
    status_item_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    location_id: uuid.UUID | None = None,
    include_sublocations: bool = True,
    holder_id: uuid.UUID | None = None,
    store_id: uuid.UUID | None = None,
    brand_id: uuid.UUID | None = None,
    at_store: bool | None = None,
    below_min_only: bool = False,
):
    stmt = select(Asset).where(Asset.deleted_at.is_(None))
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                Asset.name.ilike(like),
                Asset.asset_no.ilike(like),
                Asset.serial_no.ilike(like),
                Asset.barcode.ilike(like),
                Asset.model_name.ilike(like),
                Asset.note.ilike(like),
                Asset.store_id.in_(select(Store.id).where(Store.name.ilike(like))),
                Asset.location_id.in_(select(Location.id).where(Location.name.ilike(like))),
            )
        )
    if asset_status:
        stmt = stmt.where(Asset.status == asset_status)
    if status_item_id:
        stmt = stmt.where(Asset.status_item_id == status_item_id)
    if category_id:
        stmt = stmt.where(Asset.category_id == category_id)
    if holder_id:
        stmt = stmt.where(Asset.holder_id == holder_id)
    if location_id:
        if include_sublocations:
            stmt = stmt.where(Asset.location_id.in_(_descendant_ids(db, location_id)))
        else:
            stmt = stmt.where(Asset.location_id == location_id)
    if store_id:
        stmt = stmt.where(Asset.store_id == store_id)
    if brand_id:
        # 브랜드는 매장에 달려 있다. 자산 -> 매장 -> 브랜드로 한 단계 더 탄다.
        stmt = stmt.where(
            Asset.store_id.in_(
                select(Store.id).where(Store.brand_id == brand_id, Store.deleted_at.is_(None))
            )
        )
    if at_store is True:
        stmt = stmt.where(Asset.store_id.isnot(None))
    elif at_store is False:
        stmt = stmt.where(Asset.store_id.is_(None))
    if below_min_only:
        stmt = stmt.where(Asset.min_quantity.isnot(None), Asset.quantity < Asset.min_quantity)
    return stmt


@router.get("/assets", response_model=Page[AssetOut])
def list_assets(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    q: str | None = Query(None, description="name / asset no / serial / model / note / 매장 / 위치"),
    asset_status: AssetStatus | None = Query(None, alias="status"),
    status_item_id: uuid.UUID | None = Query(None, description="세부 상태 코드"),
    category_id: uuid.UUID | None = None,
    location_id: uuid.UUID | None = None,
    holder_id: uuid.UUID | None = None,
    store_id: uuid.UUID | None = Query(None, description="이 매장에 나가 있는 자산만"),
    brand_id: uuid.UUID | None = Query(None, description="이 브랜드의 매장에 있는 자산만"),
    at_store: bool | None = Query(None, description="true: 매장에 있는 것만 / false: 미설치(창고 등)만"),
    include_sublocations: bool = True,
    below_min_only: bool = False,
    sort: Annotated[AssetSort, Query()] = "created_desc",
) -> Page[AssetOut]:
    stmt = _asset_query(
        db, q=q, asset_status=asset_status, status_item_id=status_item_id, category_id=category_id,
        location_id=location_id, include_sublocations=include_sublocations, holder_id=holder_id,
        store_id=store_id, brand_id=brand_id, at_store=at_store, below_min_only=below_min_only,
    )
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    order = {
        "created_desc": (Asset.created_at.desc(),),
        "updated_desc": (Asset.updated_at.desc(),),
        "serial_asc": (Asset.serial_no.asc(),),
        "kind_serial": (Asset.category_id, Asset.status_item_id, Asset.serial_no),
    }[sort]
    rows = db.scalars(stmt.order_by(*order).offset(page.offset).limit(page.size)).all()
    return Page.build([AssetOut.model_validate(r) for r in rows], total, page.page, page.size)


@router.get("/assets/export.xlsx")
def export_assets(
    db: DbSession,
    _: CurrentUser,
    q: str | None = None,
    status_item_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    location_id: uuid.UUID | None = None,
    store_id: uuid.UUID | None = None,
    brand_id: uuid.UUID | None = None,
    at_store: bool | None = None,
):
    """재고 엑셀 (구 서버 '재고_날짜.xlsx'): 조건 없이 전체면 요약 시트 + 종류마다 시트 하나."""
    stmt = _asset_query(
        db, q=q, status_item_id=status_item_id, category_id=category_id,
        location_id=location_id, store_id=store_id, brand_id=brand_id, at_store=at_store,
    )
    assets = list(db.scalars(stmt).all())
    ctx = _OverviewContext(db, assets)
    kinds = [k for k in ctx.kinds if any(a.category_id == k.id for a in assets)]
    order_k = {k.id: n for n, k in enumerate(ctx.kinds)}
    order_b = {b.id: n for n, b in enumerate(ctx.brands)}

    def group_label(a: Asset) -> str:
        if a.store_id:
            return ctx.brand_name_of(a) or "(브랜드 없음)"
        return (ctx.location_name(a.location_id) or "(장소 없음)") + " (미설치)"

    assets.sort(key=lambda a: (
        order_k.get(a.category_id, 99), 0 if a.store_id else 1,
        order_b.get(ctx.brand_id_of(a), 99), ctx.store_name(a.store_id) or ctx.location_name(a.location_id) or "",
        ctx.status_name(a) or "", a.serial_no or "",
    ))
    head = ["종류", "품명", "제조사", "S/N", "상태", "브랜드", "매장", "보관 장소", "설치일", "비고", "마지막 변경", "자산번호"]
    widths = [10, 12, 14, 20, 10, 10, 22, 14, 11, 40, 18, 14]

    def line(a: Asset):
        return [
            ctx.kind_name(a.category_id) or "", a.model_name or "", a.manufacturer or "", a.serial_no or "",
            ctx.status_name(a) or a.status.value, ctx.brand_name_of(a) or "", ctx.store_name(a.store_id) or "",
            ctx.location_name(a.location_id) or "", a.purchase_date, a.note or "",
            stats.to_local(a.updated_at), a.asset_no,
        ]

    wb = excel.workbook()
    if len(kinds) > 1:
        ws = wb.create_sheet("요약")
        groups = sorted({group_label(a) for a in assets})
        rows = []
        for g in groups:
            cnt = Counter(a.category_id for a in assets if group_label(a) == g)
            rows.append([g] + [cnt.get(k.id, 0) for k in kinds] + [sum(cnt.values())])
        rows.append(["전체"] + [sum(1 for a in assets if a.category_id == k.id) for k in kinds] + [len(assets)])
        excel.fill_sheet(ws, ["구분"] + [k.name for k in kinds] + ["합계"], rows, [22] + [10] * (len(kinds) + 1))
        for k in kinds:
            excel.fill_sheet(wb.create_sheet(excel.sheet_title(k.name)), head, (line(a) for a in assets if a.category_id == k.id), widths)
    else:
        ws = wb.create_sheet(excel.sheet_title(kinds[0].name) if kinds else "재고")
        excel.fill_sheet(ws, head, (line(a) for a in assets), widths)
    return excel.to_response(wb, f"재고_{datetime.now(stats.LOCAL_TZ).date().isoformat()}.xlsx")


def _maker_required(db: Session, category_id: uuid.UUID | None, manufacturer: str | None) -> None:
    need = settings_store.get(db, ModuleKey.INVENTORY, "maker_required_categories", DEFAULT_MAKER_CATEGORIES) or []
    name = asset_rules.category_name(db, category_id)
    if name in {str(x) for x in need} and not (manufacturer or "").strip():
        raise AppError(
            "MAKER_REQUIRED",
            f"{name}은(는) 제조사를 고르세요. (목록에 없으면 [관리]→[분류 코드]의 자산 제조사에 추가)",
        )


def _check_serial(db: Session, category_id: uuid.UUID | None, serial: str | None, exclude_id: uuid.UUID | None = None) -> None:
    if not serial:
        return
    dup = asset_rules.serial_taken(db, category_id, serial, exclude_id)
    if dup is not None:
        kind = asset_rules.category_name(db, category_id) or ""
        raise AppError(
            "SERIAL_TAKEN",
            f"{kind} {serial} 은(는) 이미 있습니다 ({dup.asset_no}).",
            status.HTTP_409_CONFLICT,
            {"asset_id": str(dup.id), "asset_no": dup.asset_no},
        )


def _place_new_asset(db: Session, asset: Asset, *, status_item_id: uuid.UUID | None, requested_location_id: uuid.UUID | None) -> None:
    """등록 때 세부 상태 규칙 적용. 상태가 없으면 자리(매장/위치)에서 어울리는 상태를 고른다."""
    if asset.store_id is not None:
        asset_rules.load_store(db, asset.store_id)
    item = asset_rules.load_status_item(db, status_item_id) if status_item_id else None
    if item is None:
        item = asset_rules.default_item_for_destination(db, store_id=asset.store_id, location_id=requested_location_id)
    if item is not None:
        asset_rules.apply_status(db, asset, item, requested_location_id=requested_location_id)
    if settings_store.get(db, ModuleKey.INVENTORY, "require_location", True) and not (
        asset.location_id or asset.store_id
    ):
        raise AppError("LOCATION_REQUIRED", "자산 등록 시 위치 또는 매장 중 하나는 지정해야 합니다.")


@router.post("/assets", response_model=AssetDetail, status_code=status.HTTP_201_CREATED)
def create_asset(
    payload: AssetCreate, db: DbSession, user: CurrentUser, client: Client
) -> AssetDetail:
    data = payload.model_dump()
    asset_no = data.pop("asset_no", None)
    status_item_id = data.pop("status_item_id", None)
    data["serial_no"] = asset_rules.normalise_serial(data.get("serial_no"))

    _maker_required(db, data.get("category_id"), data.get("manufacturer"))
    _check_serial(db, data.get("category_id"), data.get("serial_no"))

    asset = Asset(**data, created_by_id=user.id)
    _place_new_asset(db, asset, status_item_id=status_item_id, requested_location_id=data.get("location_id"))
    _insert_asset(db, asset, asset_no)
    _record_inbound(db, asset, user)
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.INVENTORY,
        entity_type="asset",
        entity_id=asset.id,
        summary=f"자산 등록 {asset.asset_no}: {asset.name}",
        client=client,
    )
    db.commit()
    return _detail(db, asset.id)


@router.post("/assets/bulk", response_model=BulkCreateResult, status_code=status.HTTP_201_CREATED)
def create_assets_bulk(
    payload: AssetBulkCreate, db: DbSession, user: CurrentUser, client: Client
) -> BulkCreateResult:
    """S/N 여러 개를 한 번에 (구 서버 입고·등록 화면). 이미 있는 S/N 은 건너뛰고 알려 준다."""
    serials: list[str] = []
    for chunk in payload.serial_nos:
        for s in split_serials(chunk):
            if s not in serials:
                serials.append(s)
    if not serials:
        raise AppError("SERIAL_REQUIRED", "S/N 을 입력하세요.")
    _maker_required(db, payload.category_id, payload.manufacturer)
    kind = asset_rules.category_name(db, payload.category_id) or ""
    name = (payload.name or f"{kind} {payload.model_name or ''}").strip() or kind or "장비"

    created: list[Asset] = []
    dup: list[str] = []
    for s in serials:
        if asset_rules.serial_taken(db, payload.category_id, s) is not None:
            dup.append(s)
            continue
        asset = Asset(
            name=name, category_id=payload.category_id, model_name=payload.model_name,
            manufacturer=payload.manufacturer, serial_no=s, location_id=payload.location_id,
            store_id=payload.store_id, set_no=payload.set_no if payload.store_id else 0,
            purchase_date=payload.purchase_date, note=payload.note, created_by_id=user.id,
        )
        _place_new_asset(db, asset, status_item_id=payload.status_item_id, requested_location_id=payload.location_id)
        _insert_asset(db, asset, None)
        _record_inbound(db, asset, user)
        created.append(asset)
    if created:
        audit.record(
            db,
            action=AuditAction.CREATE,
            actor=user,
            module=ModuleKey.INVENTORY,
            entity_type="asset",
            entity_id=created[0].id,
            summary=f"자산 {len(created)}대 등록: {kind} " + ", ".join(a.serial_no or "" for a in created[:10]),
            client=client,
        )
    db.commit()
    return BulkCreateResult(created=[AssetOut.model_validate(a) for a in created], duplicates=dup)


@router.get("/assets/{asset_id}", response_model=AssetDetail)
def get_asset(asset_id: uuid.UUID, db: DbSession, _: CurrentUser) -> AssetDetail:
    return _detail(db, asset_id)


@router.patch("/assets/{asset_id}", response_model=AssetDetail)
def update_asset(
    asset_id: uuid.UUID,
    payload: AssetUpdate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> AssetDetail:
    asset = _load(db, asset_id)
    data = payload.model_dump(exclude_unset=True)
    status_item_id = data.pop("status_item_id", None)
    if "serial_no" in data:
        data["serial_no"] = asset_rules.normalise_serial(data["serial_no"])
    before = {k: getattr(asset, k) for k in data}
    category_id = data.get("category_id", asset.category_id)
    if "serial_no" in data or "category_id" in data:
        _check_serial(db, category_id, data.get("serial_no", asset.serial_no), exclude_id=asset.id)
    if "manufacturer" in data or "category_id" in data:
        _maker_required(db, category_id, data.get("manufacturer", asset.manufacturer))
    for field, value in data.items():
        setattr(asset, field, value)
    if status_item_id is not None and status_item_id != asset.status_item_id:
        # 상태는 이력이 남아야 한다. PATCH 로 와도 이동과 같은 길을 탄다.
        _apply_move(db, asset, AssetMoveRequest(to_status_item_id=status_item_id, reason="상태 수정"), user)
    asset.updated_by_id = user.id
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.INVENTORY,
        entity_type="asset",
        entity_id=asset.id,
        summary=f"자산 수정 {asset.asset_no}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    return _detail(db, asset_id)


@router.post("/assets/{asset_id}/move", response_model=AssetDetail)
def move_asset(
    asset_id: uuid.UUID,
    payload: AssetMoveRequest,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> AssetDetail:
    """위치/매장/보관자/상태 변경의 단일 경로. 자산 현재값과 이력을 함께 갱신합니다.

    세부 상태(`to_status_item_id`)를 주면 그 규칙이 매장·위치를 정리한다:
    설치·렌탈 중은 매장 필수, 창고·사무실·미상은 매장을 비우고 그 이름의 위치로,
    AS 대기·AS 반출은 매장에 둔 채 상태만. 상태 없이 자리만 옮기면 자리에 맞는
    상태를 서버가 고른다(매장 → 설치, 창고 위치 → 창고).
    """
    asset = _load(db, asset_id)
    movement = _apply_move(db, asset, payload, user)
    if movement is None:
        raise AppError("NO_CHANGE", "이미 그 상태·그 자리입니다.")
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.INVENTORY,
        entity_type="asset",
        entity_id=asset.id,
        summary=f"자산 이동 {asset.asset_no}: {payload.movement_type.value}",
        client=client,
    )
    db.commit()
    return _detail(db, asset_id)


@router.post("/assets/bulk-move", response_model=BulkMoveResult)
def move_assets_bulk(
    payload: AssetBulkMoveRequest, db: DbSession, user: CurrentUser, client: Client
) -> BulkMoveResult:
    """목록에서 고른 장비 여러 대를 한 번에 (한 대씩과 같은 규칙 · 같은 이력)."""
    moved: list[str] = []
    skipped: list[str] = []
    errors: list[str] = []
    single = AssetMoveRequest(**payload.model_dump(exclude={"asset_ids"}))
    for aid in payload.asset_ids:
        asset = db.scalar(select(Asset).where(Asset.id == aid, Asset.deleted_at.is_(None)))
        if asset is None:
            errors.append(f"{aid}: 자산을 찾을 수 없습니다.")
            continue
        label = f"{asset_rules.category_name(db, asset.category_id) or asset.name} {asset.serial_no or asset.asset_no}"
        try:
            with db.begin_nested():
                movement = _apply_move(db, asset, single, user, bulk_note=f"여러 대 한 번에({len(payload.asset_ids)}대)")
        except AppError as e:
            errors.append(f"{label}: {e.message}")
            continue
        (moved if movement is not None else skipped).append(label)
    if moved:
        audit.record(
            db,
            action=AuditAction.UPDATE,
            actor=user,
            module=ModuleKey.INVENTORY,
            entity_type="asset",
            entity_id=payload.asset_ids[0],
            summary=f"자산 {len(moved)}대 일괄 이동: " + ", ".join(moved[:10]),
            client=client,
        )
    db.commit()
    return BulkMoveResult(moved=moved, skipped=skipped, errors=errors)


# A movement type carries an obvious resulting status unless one is given.
_IMPLIED_STATUS = {
    MovementType.ASSIGN: AssetStatus.IN_USE,
    MovementType.RETURN: AssetStatus.IN_STOCK,
    MovementType.REPAIR: AssetStatus.REPAIR,
    MovementType.DISPOSE: AssetStatus.DISPOSED,
}


def _apply_move(
    db: Session, asset: Asset, payload: AssetMoveRequest, user: User, *, bulk_note: str | None = None
) -> AssetMovement | None:
    """이동 한 건을 자산에 적용하고 이력 행을 만든다. 바뀐 것이 없으면 None."""
    before = (asset.status_item_id, asset.status, asset.store_id, asset.location_id, asset.holder_id, asset.set_no)
    movement = AssetMovement(
        asset_id=asset.id,
        movement_type=payload.movement_type,
        from_location_id=asset.location_id,
        from_holder_id=asset.holder_id,
        from_status=asset.status,
        from_store_id=asset.store_id,
        from_status_item_id=asset.status_item_id,
        # to_* 는 아래에서 자산을 고친 뒤 그 결과로 채운다. 요청에 실려 온
        # 값만 적으면, 상태만 바꾼 이동이 "매장에서 나감"으로 읽힌다.
        quantity=payload.quantity if payload.quantity is not None else asset.quantity,
        moved_at=payload.moved_at or now_utc(),
        moved_by_id=user.id,
        reason=payload.reason,
        reference_type=payload.reference_type,
        reference_id=payload.reference_id,
    )

    # 자산은 우리 위치에 있거나 매장에 나가 있거나 둘 중 하나다. 한쪽을
    # 채우면 반대쪽을 비워야 두 칸이 동시에 차서 "어디 있는지 모르는" 행이
    # 생기지 않는다. 구 서버도 store 와 place 를 이렇게 배타적으로 다뤘다.
    requested_location = payload.to_location_id
    if payload.to_store_id is not None:
        asset_rules.load_store(db, payload.to_store_id)
        if asset.store_id != payload.to_store_id:
            asset.set_no = 0                       # 다른 매장으로 가면 세트 미지정
        asset.store_id = payload.to_store_id
        asset.location_id = None
    elif payload.to_location_id is not None:
        asset.location_id = payload.to_location_id
        asset.store_id = None
        asset.set_no = 0
    elif payload.clear_store:
        asset.store_id = None
        asset.set_no = 0

    if payload.to_holder_id is not None:
        asset.holder_id = payload.to_holder_id

    item = asset_rules.load_status_item(db, payload.to_status_item_id) if payload.to_status_item_id else None
    if item is None and (payload.to_store_id is not None or payload.to_location_id is not None or payload.clear_store):
        # 자리만 옮겼다: 지금 상태가 새 자리와 어긋나면 자리에 맞는 상태로.
        current = db.get(CodeItem, asset.status_item_id) if asset.status_item_id else None
        at_store_now = asset.store_id is not None
        if current is None or asset_rules.is_at_store_rule(current) != at_store_now:
            item = asset_rules.default_item_for_destination(
                db, store_id=asset.store_id, location_id=asset.location_id,
                leaving_store=(before[2] is not None and asset.store_id is None),
            )
    if item is not None:
        asset_rules.apply_status(db, asset, item, requested_location_id=requested_location)
    elif payload.to_status is not None:
        asset.status = payload.to_status
    elif payload.movement_type in _IMPLIED_STATUS:
        asset.status = _IMPLIED_STATUS[payload.movement_type]

    # 세트는 그 매장 안에서만 뜻이 있다. 매장을 떠나면 미지정으로 되돌린다.
    if payload.to_set_no is not None and asset.store_id is not None:
        asset.set_no = payload.to_set_no
    elif asset.store_id is None:
        asset.set_no = 0

    if payload.movement_type == MovementType.RETURN:
        asset.holder_id = None
    if payload.movement_type == MovementType.DISPOSE:
        asset.disposed_at = movement.moved_at
    if payload.movement_type == MovementType.STOCKTAKE and payload.quantity is not None:
        asset.quantity = payload.quantity

    after = (asset.status_item_id, asset.status, asset.store_id, asset.location_id, asset.holder_id, asset.set_no)
    if after == before and payload.movement_type not in (MovementType.STOCKTAKE, MovementType.DISPOSE):
        return None

    asset.updated_by_id = user.id
    # 결과 상태를 이력에 박는다. from_* 가 "직전 상태"이므로 to_* 도
    # "직후 상태"여야 한 줄만 읽고도 무엇이 바뀌었는지 알 수 있다.
    movement.to_location_id = asset.location_id
    movement.to_holder_id = asset.holder_id
    movement.to_status = asset.status
    movement.to_store_id = asset.store_id
    movement.to_status_item_id = asset.status_item_id
    if bulk_note:
        movement.reason = " · ".join(x for x in (movement.reason, bulk_note) if x)
    db.add(movement)
    return movement


@router.get("/assets/{asset_id}/movements", response_model=Page[AssetMovementOut])
def asset_movements(
    asset_id: uuid.UUID, db: DbSession, _: CurrentUser, page: PageParams
) -> Page[AssetMovementOut]:
    stmt = select(AssetMovement).where(AssetMovement.asset_id == asset_id)
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(AssetMovement.moved_at.desc()).offset(page.offset).limit(page.size)
    ).all()
    return Page.build(
        [AssetMovementOut.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.delete("/assets/{asset_id}", response_model=Message)
def delete_asset(
    asset_id: uuid.UUID, db: DbSession, manager: ManagerUser, client: Client
) -> Message:
    asset = _load(db, asset_id)
    asset.deleted_at = now_utc()
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=manager,
        module=ModuleKey.INVENTORY,
        entity_type="asset",
        entity_id=asset.id,
        summary=f"자산 삭제 {asset.asset_no}",
        client=client,
    )
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== overview (구 서버 재고 › 현황)
class _OverviewContext:
    """현황 · 엑셀이 같이 쓰는 이름표. 쿼리 몇 번으로 종류 · 상태 · 매장 · 브랜드 · 위치 이름을 끌어온다."""

    def __init__(self, db: Session, assets: list[Asset]):
        self.db = db
        self.kinds = _group_items(db, asset_rules.CATEGORY_GROUP, active_only=False)
        self.statuses = asset_rules.status_items(db, active_only=False)
        self.brands = _group_items(db, "STORE_BRAND", active_only=False)
        self._kind = {k.id: k for k in self.kinds}
        self._status = {s.id: s for s in self.statuses}
        self._brand = {b.id: b for b in self.brands}
        store_ids = {a.store_id for a in assets if a.store_id}
        self._store = {s.id: s for s in db.scalars(select(Store).where(Store.id.in_(store_ids))).all()} if store_ids else {}
        loc_ids = {a.location_id for a in assets if a.location_id}
        self._loc = {l.id: l for l in db.scalars(select(Location).where(Location.id.in_(loc_ids))).all()} if loc_ids else {}

    def kind_name(self, cid):
        k = self._kind.get(cid) if cid else None
        return k.name if k else None

    def status_item(self, a: Asset) -> CodeItem | None:
        return self._status.get(a.status_item_id) if a.status_item_id else None

    def status_name(self, a: Asset):
        s = self.status_item(a)
        return s.name if s else None

    def store_name(self, sid):
        s = self._store.get(sid) if sid else None
        return s.name if s else None

    def brand_id_of(self, a: Asset):
        s = self._store.get(a.store_id) if a.store_id else None
        return s.brand_id if s else None

    def brand_name_of(self, a: Asset):
        b = self._brand.get(self.brand_id_of(a)) if self.brand_id_of(a) else None
        return b.name if b else None

    def location_name(self, lid):
        l = self._loc.get(lid) if lid else None
        return l.name if l else None


def _group_items(db: Session, group_code: str, active_only: bool = True) -> list[CodeItem]:
    group = db.scalar(select(CodeGroup).where(CodeGroup.code == group_code))
    if group is None:
        return []
    stmt = select(CodeItem).where(CodeItem.group_id == group.id, CodeItem.deleted_at.is_(None))
    if active_only:
        stmt = stmt.where(CodeItem.is_active.is_(True))
    return list(db.scalars(stmt.order_by(CodeItem.sort_order, CodeItem.name)))


@router.get("/overview", response_model=InventoryOverview)
def overview(db: DbSession, _: CurrentUser) -> InventoryOverview:
    """구 서버 재고 › 현황. 상태×종류, 브랜드×종류(매장 설치), 장소×종류(미설치), 확인 목록(AS·미상), 렌탈 중."""
    assets = list(db.scalars(select(Asset).where(Asset.deleted_at.is_(None))).all())
    ctx = _OverviewContext(db, assets)
    used_kinds = {a.category_id for a in assets}
    kinds = [k for k in ctx.kinds if k.is_active or k.id in used_kinds]
    kind_key = lambda a: str(a.category_id) if a.category_id else "-"

    def rows(groups: dict, order: list[tuple[str, str, str | None]]) -> list[OverviewRow]:
        out = []
        for key, label, color in order:
            cnt = groups.get(key)
            if cnt is None:
                continue
            out.append(OverviewRow(key=key, label=label, color=color, counts=dict(cnt), total=sum(cnt.values())))
        return out

    by_status: dict[str, Counter] = defaultdict(Counter)
    by_brand: dict[str, Counter] = defaultdict(Counter)
    by_place: dict[str, Counter] = defaultdict(Counter)
    for a in assets:
        s = ctx.status_item(a)
        by_status[str(s.id) if s else a.status.value][kind_key(a)] += 1
        if a.store_id:
            bid = ctx.brand_id_of(a)
            by_brand[str(bid) if bid else "-"][kind_key(a)] += 1
        else:
            by_place[str(a.location_id) if a.location_id else "-"][kind_key(a)] += 1

    status_order = [(str(s.id), s.name, s.color) for s in ctx.statuses] + [
        (e.value, e.value, None) for e in AssetStatus
    ]
    brand_order = [(str(b.id), b.name, b.color) for b in ctx.brands] + [("-", "(브랜드 없음)", None)]
    place_ids = {a.location_id for a in assets if not a.store_id and a.location_id}
    places = sorted((ctx._loc[l] for l in place_ids if l in ctx._loc), key=lambda l: (l.sort_order, l.name))
    place_order = [(str(l.id), l.name, None) for l in places] + [("-", "(장소 없음)", None)]

    def brief(a: Asset) -> dict:
        return dict(
            id=a.id, asset_no=a.asset_no, name=a.name, category_id=a.category_id,
            category_name=ctx.kind_name(a.category_id), serial_no=a.serial_no, status_name=ctx.status_name(a),
            store_id=a.store_id, store_name=ctx.store_name(a.store_id),
            location_name=ctx.location_name(a.location_id), note=a.note,
        )

    def needs_attention(a: Asset) -> bool:
        s = ctx.status_item(a)
        if s is not None:
            r = asset_rules.rule_of(s)
            return r.kind == "as" or r.enum == AssetStatus.LOST
        return a.status in (AssetStatus.REPAIR, AssetStatus.LOST)

    attention = sorted((a for a in assets if needs_attention(a)), key=lambda a: (ctx.status_name(a) or "", ctx.kind_name(a.category_id) or "", a.serial_no or ""))

    # 렌탈 중: 그 S/N 이 적힌 미회수 렌탈 기록(최근 것)의 번호 · 회수 예정일 · D-day
    today = datetime.now(stats.LOCAL_TZ).date()
    loaned = [a for a in assets if (s := ctx.status_item(a)) is not None and asset_rules.rule_of(s).enum == AssetStatus.LOANED or (ctx.status_item(a) is None and a.status == AssetStatus.LOANED)]
    open_rentals = list(db.scalars(
        select(ServiceTicket).where(
            ServiceTicket.deleted_at.is_(None), ServiceTicket.is_rental.is_(True), ServiceTicket.rental_returned.is_(False)
        ).order_by(ServiceTicket.received_at.desc())
    ).all())
    by_serial: dict[str, ServiceTicket] = {}
    for t in open_rentals:
        for sn in split_serials(t.rental_serials):
            by_serial.setdefault(sn.lower(), t)
    rentals = []
    for a in sorted(loaned, key=lambda a: (ctx.brand_name_of(a) or "", ctx.store_name(a.store_id) or "", ctx.kind_name(a.category_id) or "", a.serial_no or "")):
        t = by_serial.get((a.serial_no or "").lower())
        rentals.append(RentalAsset(
            **brief(a),
            ticket_id=t.id if t else None, ticket_no=t.ticket_no if t else None,
            rented_at=t.received_at if t else None, due_date=t.rental_due_date if t else None,
            dday=(t.rental_due_date - today).days if t and t.rental_due_date else None,
        ))

    return InventoryOverview(
        total=len(assets),
        kinds=[CodeItemBrief.model_validate(k) for k in kinds],
        statuses=[CodeItemBrief.model_validate(s) for s in ctx.statuses if s.is_active],
        by_status=rows(by_status, status_order),
        by_brand=rows(by_brand, brand_order),
        by_place=rows(by_place, place_order),
        attention=[AttentionAsset(**brief(a)) for a in attention],
        rentals=rentals,
    )


# ================================================================== summary
@router.get("/summary", response_model=InventorySummary)
def summary(db: DbSession, _: CurrentUser) -> InventorySummary:
    """대시보드용 집계: 상태별 / 분류별 / 위치별 보유 현황."""
    live = Asset.deleted_at.is_(None)

    total_assets = db.scalar(select(func.count(Asset.id)).where(live)) or 0
    total_qty = db.scalar(select(func.sum(Asset.quantity)).where(live)) or 0
    total_value = db.scalar(
        select(func.sum(Asset.quantity * Asset.purchase_price)).where(
            live, Asset.purchase_price.isnot(None)
        )
    )

    by_status = [
        CountBucket(key=str(s), label=str(s), count=c, quantity=Decimal(str(q or 0)))
        for s, c, q in db.execute(
            select(Asset.status, func.count(Asset.id), func.sum(Asset.quantity))
            .where(live)
            .group_by(Asset.status)
        ).all()
    ]
    by_category = [
        CountBucket(
            key=str(name or "미분류"),
            label=str(name or "미분류"),
            count=c,
            quantity=Decimal(str(q or 0)),
        )
        for name, c, q in db.execute(
            select(
                func.coalesce(CodeItem.name, "미분류"),
                func.count(Asset.id),
                func.sum(Asset.quantity),
            )
            .select_from(Asset)
            .outerjoin(CodeItem, CodeItem.id == Asset.category_id)
            .where(live)
            .group_by(CodeItem.id, CodeItem.name)
        ).all()
    ]
    by_location = [
        CountBucket(
            key=str(path or "미지정"),
            label=str(path or "미지정"),
            count=c,
            quantity=Decimal(str(q or 0)),
        )
        for path, c, q in db.execute(
            select(
                func.coalesce(Location.path, Location.name),
                func.count(Asset.id),
                func.sum(Asset.quantity),
            )
            .select_from(Asset)
            .outerjoin(Location, Location.id == Asset.location_id)
            .where(live)
            .group_by(Location.id, Location.path, Location.name)
        ).all()
    ]

    below_min = db.scalar(
        select(func.count(Asset.id)).where(
            live, Asset.min_quantity.isnot(None), Asset.quantity < Asset.min_quantity
        )
    ) or 0
    alert_days = settings_store.get(db, ModuleKey.INVENTORY, "warranty_alert_days", 30)
    expiring = db.scalar(
        select(func.count(Asset.id)).where(
            live,
            Asset.warranty_until.isnot(None),
            Asset.warranty_until <= date.today() + timedelta(days=int(alert_days or 30)),
            Asset.warranty_until >= date.today(),
        )
    ) or 0

    return InventorySummary(
        total_assets=total_assets,
        total_quantity=Decimal(str(total_qty)),
        total_value=Decimal(str(total_value)) if total_value is not None else None,
        by_status=by_status,
        by_category=by_category,
        by_location=by_location,
        below_min_count=below_min,
        warranty_expiring_count=expiring,
    )


# ================================================================== helpers
def _load(db: Session, asset_id: uuid.UUID) -> Asset:
    asset = db.scalar(
        select(Asset).where(Asset.id == asset_id, Asset.deleted_at.is_(None))
    )
    if asset is None:
        raise AppError("NOT_FOUND", "자산을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    return asset




def _detail(db: Session, asset_id: uuid.UUID) -> AssetDetail:
    asset = _load(db, asset_id)
    out = AssetDetail.model_validate(asset)
    out.is_below_min = asset.is_below_min
    if asset.location_id:
        loc = db.get(Location, asset.location_id)
        out.location = LocationOut.model_validate(loc) if loc else None
    if asset.holder_id:
        holder = db.get(User, asset.holder_id)
        out.holder = UserBrief.model_validate(holder) if holder else None
    if asset.category_id:
        cat = db.get(CodeItem, asset.category_id)
        out.category = CodeItemBrief.model_validate(cat) if cat else None
    if asset.store_id:
        store = db.get(Store, asset.store_id)
        out.store = StoreBrief.model_validate(store) if store else None
    if asset.status_item_id:
        item = db.get(CodeItem, asset.status_item_id)
        out.status_item = CodeItemBrief.model_validate(item) if item else None
    return out


def _build_path(db: Session, parent_id: uuid.UUID | None, name: str) -> str:
    if parent_id is None:
        return name
    parent = db.get(Location, parent_id)
    if parent is None:
        return name
    return f"{parent.path or parent.name} > {name}"


def _refresh_descendant_paths(db: Session, parent: Location) -> None:
    """Re-denormalise the cached path of everything under a moved/renamed node."""
    children = db.scalars(
        select(Location).where(
            Location.parent_id == parent.id, Location.deleted_at.is_(None)
        )
    ).all()
    for child in children:
        child.path = f"{parent.path} > {child.name}"
        _refresh_descendant_paths(db, child)


def _descendant_ids(db: Session, root_id: uuid.UUID) -> list[uuid.UUID]:
    """Location ids of a subtree, root included.

    Iterative rather than a recursive CTE so the same code runs on SQLite; the
    location tree is small enough that the extra round trips do not matter.
    """
    ids = [root_id]
    frontier = [root_id]
    while frontier:
        children = db.scalars(
            select(Location.id).where(
                Location.parent_id.in_(frontier), Location.deleted_at.is_(None)
            )
        ).all()
        children = [c for c in children if c not in ids]
        if not children:
            break
        ids.extend(children)
        frontier = children
    return ids


def _insert_with_asset_no(db: Session, asset: Asset, retries: int = 5) -> None:
    prefix = settings_store.get(db, ModuleKey.INVENTORY, "asset_no_prefix", "AST") or "AST"
    year = now_utc().strftime("%Y")
    like = f"{prefix}-{year}-%"
    base = db.scalar(
        select(func.count(Asset.id)).where(Asset.asset_no.like(like))
    ) or 0
    for attempt in range(retries):
        asset.asset_no = f"{prefix}-{year}-{base + 1 + attempt:05d}"
        try:
            with db.begin_nested():
                db.add(asset)
                db.flush()
            return
        except IntegrityError:
            continue
    raise AppError(
        "ASSET_NO_CONFLICT",
        "자산번호 채번에 실패했습니다. 잠시 후 다시 시도해 주세요.",
        status.HTTP_409_CONFLICT,
    )


def _insert_asset(db: Session, asset: Asset, asset_no: str | None) -> None:
    """자산번호를 직접 주면 그대로, 없으면 채번(AST-YYYY-00001)."""
    if asset_no:
        if db.scalar(select(Asset.id).where(Asset.asset_no == asset_no)):
            raise AppError("ASSET_NO_TAKEN", "이미 사용 중인 자산번호입니다.", status.HTTP_409_CONFLICT)
        asset.asset_no = asset_no
        db.add(asset)
        db.flush()
        return
    _insert_with_asset_no(db, asset)


def _record_inbound(db: Session, asset: Asset, user: User) -> None:
    """Registering a unit is itself a movement, so the history starts complete."""
    db.add(
        AssetMovement(
            asset_id=asset.id,
            movement_type=MovementType.INBOUND,
            to_location_id=asset.location_id,
            to_store_id=asset.store_id,
            to_holder_id=asset.holder_id,
            to_status=asset.status,
            to_status_item_id=asset.status_item_id,
            quantity=asset.quantity,
            moved_at=now_utc(),
            moved_by_id=user.id,
            reason="신규 등록",
        )
    )
