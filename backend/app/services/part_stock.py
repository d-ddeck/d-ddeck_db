"""Atomic quantity adjustment with an explicit per-part reversal amount."""

from decimal import Decimal

from sqlalchemy import select, update

from app.core.errors import AppError
from app.core.security import now_utc
from app.models.enums import ModuleKey, MovementType
from app.models.inventory import Asset, AssetMovement
from app.models.service import ServicePart
from app.services import settings_store


def _movement(db, asset, part, user, quantity, reason):
    db.add(
        AssetMovement(
            asset_id=asset.id,
            movement_type=MovementType.STOCKTAKE,
            from_status=asset.status,
            to_status=asset.status,
            from_location_id=asset.location_id,
            to_location_id=asset.location_id,
            from_store_id=asset.store_id,
            to_store_id=asset.store_id,
            from_status_item_id=asset.status_item_id,
            to_status_item_id=asset.status_item_id,
            quantity=quantity,
            moved_at=now_utc(),
            moved_by_id=user.id,
            reference_type="service_ticket",
            reference_id=part.ticket_id,
            reason=reason,
        )
    )


def deduct(db, part, user):
    part.stock_deducted = 0
    if (
        not settings_store.get(db, ModuleKey.SERVICE, "auto_deduct_parts", False)
        or part.asset_id is None
    ):
        return
    quantity = Decimal(str(part.quantity))
    asset = db.scalar(
        select(Asset).where(Asset.id == part.asset_id, Asset.deleted_at.is_(None))
    )
    if asset is None:
        raise AppError("ASSET_NOT_FOUND", "재고 자산을 찾을 수 없습니다.", 404)
    changed = db.execute(
        update(Asset)
        .where(
            Asset.id == asset.id, Asset.quantity >= quantity, Asset.deleted_at.is_(None)
        )
        .values(quantity=Asset.quantity - quantity)
    ).rowcount
    if changed != 1:
        raise AppError("INSUFFICIENT_STOCK", "사용 수량보다 재고가 부족합니다.", 409)
    part.stock_deducted = quantity
    _movement(db, asset, part, user, -quantity, "대응 사용 부품 자동 차감")


def restore(db, part, user):
    amount = Decimal(str(part.stock_deducted or 0))
    if not amount or not part.asset_id:
        return
    asset = db.get(Asset, part.asset_id)
    if asset is None:
        raise AppError(
            "ASSET_NOT_FOUND", "차감한 재고를 찾을 수 없어 삭제할 수 없습니다.", 409
        )
    claimed = db.execute(
        update(ServicePart)
        .where(ServicePart.id == part.id, ServicePart.stock_deducted == amount)
        .values(stock_deducted=0)
    ).rowcount
    if claimed != 1:
        return
    db.execute(
        update(Asset)
        .where(Asset.id == asset.id)
        .values(quantity=Asset.quantity + amount)
    )
    _movement(db, asset, part, user, amount, "사용 부품 취소로 재고 복구")
    part.stock_deducted = 0
