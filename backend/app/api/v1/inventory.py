"""재고관리 module: locations, assets, and the movement history that tracks
where each unit actually is."""
from __future__ import annotations

import uuid
from datetime import date, timedelta
from decimal import Decimal

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
from app.models.admin import CodeItem
from app.models.enums import (
    AssetStatus,
    AuditAction,
    ModuleKey,
    MovementType,
)
from app.models.inventory import Asset, AssetMovement, Location
from app.models.user import User
from app.schemas.common import CodeItemBrief, Message, Page, UserBrief
from app.schemas.inventory import (
    AssetCreate,
    AssetDetail,
    AssetMoveRequest,
    AssetMovementOut,
    AssetOut,
    AssetUpdate,
    CountBucket,
    InventorySummary,
    LocationCreate,
    LocationNode,
    LocationOut,
    LocationUpdate,
)
from app.services import audit, settings_store

router = APIRouter(prefix="/inventory", tags=["inventory"])


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
@router.get("/assets", response_model=Page[AssetOut])
def list_assets(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    q: str | None = Query(None, description="name / asset no / serial / barcode"),
    asset_status: AssetStatus | None = Query(None, alias="status"),
    category_id: uuid.UUID | None = None,
    location_id: uuid.UUID | None = None,
    holder_id: uuid.UUID | None = None,
    include_sublocations: bool = True,
    below_min_only: bool = False,
) -> Page[AssetOut]:
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
            )
        )
    if asset_status:
        stmt = stmt.where(Asset.status == asset_status)
    if category_id:
        stmt = stmt.where(Asset.category_id == category_id)
    if holder_id:
        stmt = stmt.where(Asset.holder_id == holder_id)
    if location_id:
        if include_sublocations:
            stmt = stmt.where(Asset.location_id.in_(_descendant_ids(db, location_id)))
        else:
            stmt = stmt.where(Asset.location_id == location_id)
    if below_min_only:
        stmt = stmt.where(
            Asset.min_quantity.isnot(None), Asset.quantity < Asset.min_quantity
        )

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(Asset.created_at.desc()).offset(page.offset).limit(page.size)
    ).all()
    return Page.build(
        [AssetOut.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.post("/assets", response_model=AssetDetail, status_code=status.HTTP_201_CREATED)
def create_asset(
    payload: AssetCreate, db: DbSession, user: CurrentUser, client: Client
) -> AssetDetail:
    data = payload.model_dump()
    asset_no = data.pop("asset_no", None)

    if settings_store.get(db, ModuleKey.INVENTORY, "require_location", True) and not data.get(
        "location_id"
    ):
        raise AppError("LOCATION_REQUIRED", "자산 등록 시 위치는 필수입니다.")

    asset = Asset(**data, created_by_id=user.id)
    if asset_no:
        if db.scalar(select(Asset.id).where(Asset.asset_no == asset_no)):
            raise AppError("ASSET_NO_TAKEN", "이미 사용 중인 자산번호입니다.", status.HTTP_409_CONFLICT)
        asset.asset_no = asset_no
        db.add(asset)
        db.flush()
    else:
        _insert_with_asset_no(db, asset)

    # Registering a unit is itself a movement, so the history starts complete.
    db.add(
        AssetMovement(
            asset_id=asset.id,
            movement_type=MovementType.INBOUND,
            to_location_id=asset.location_id,
            to_holder_id=asset.holder_id,
            to_status=asset.status,
            quantity=asset.quantity,
            moved_at=now_utc(),
            moved_by_id=user.id,
            reason="신규 등록",
        )
    )
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
    before = {k: getattr(asset, k) for k in data}
    for field, value in data.items():
        setattr(asset, field, value)
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
    """위치/보관자/상태 변경의 단일 경로. 자산 현재값과 이력을 함께 갱신합니다."""
    asset = _load(db, asset_id)
    movement = AssetMovement(
        asset_id=asset.id,
        movement_type=payload.movement_type,
        from_location_id=asset.location_id,
        from_holder_id=asset.holder_id,
        from_status=asset.status,
        to_location_id=payload.to_location_id,
        to_holder_id=payload.to_holder_id,
        to_status=payload.to_status,
        quantity=payload.quantity if payload.quantity is not None else asset.quantity,
        moved_at=payload.moved_at or now_utc(),
        moved_by_id=user.id,
        reason=payload.reason,
        reference_type=payload.reference_type,
        reference_id=payload.reference_id,
    )

    if payload.to_location_id is not None:
        asset.location_id = payload.to_location_id
    if payload.to_holder_id is not None:
        asset.holder_id = payload.to_holder_id
    if payload.to_status is not None:
        asset.status = payload.to_status
    elif payload.movement_type in _IMPLIED_STATUS:
        asset.status = _IMPLIED_STATUS[payload.movement_type]

    if payload.movement_type == MovementType.RETURN:
        asset.holder_id = None
    if payload.movement_type == MovementType.DISPOSE:
        asset.disposed_at = movement.moved_at
    if payload.movement_type == MovementType.STOCKTAKE and payload.quantity is not None:
        asset.quantity = payload.quantity

    asset.updated_by_id = user.id
    db.add(movement)
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


# A movement type carries an obvious resulting status unless one is given.
_IMPLIED_STATUS = {
    MovementType.ASSIGN: AssetStatus.IN_USE,
    MovementType.RETURN: AssetStatus.IN_STOCK,
    MovementType.REPAIR: AssetStatus.REPAIR,
    MovementType.DISPOSE: AssetStatus.DISPOSED,
}


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
