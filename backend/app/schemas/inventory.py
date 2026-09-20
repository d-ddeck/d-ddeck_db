"""재고관리 payloads: locations, assets, movements, stock summary."""
from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, Field

from app.models.enums import AssetStatus, LocationType, MovementType
from app.schemas.common import CodeItemBrief, ORMModel, UserBrief


# ---------------------------------------------------------------- locations
class LocationCreate(BaseModel):
    code: str = Field(min_length=1, max_length=60)
    name: str = Field(min_length=1, max_length=120)
    type: LocationType = LocationType.ETC
    parent_id: uuid.UUID | None = None
    address: str | None = Field(None, max_length=300)
    manager_id: uuid.UUID | None = None
    sort_order: int = 0
    note: str | None = None


class LocationUpdate(BaseModel):
    name: str | None = Field(None, max_length=120)
    type: LocationType | None = None
    parent_id: uuid.UUID | None = None
    address: str | None = Field(None, max_length=300)
    manager_id: uuid.UUID | None = None
    sort_order: int | None = None
    is_active: bool | None = None
    note: str | None = None


class LocationOut(ORMModel):
    id: uuid.UUID
    code: str
    name: str
    type: LocationType
    parent_id: uuid.UUID | None = None
    path: str | None = None
    address: str | None = None
    manager_id: uuid.UUID | None = None
    sort_order: int
    is_active: bool
    note: str | None = None


class LocationNode(LocationOut):
    """Tree response for the location picker."""

    children: list["LocationNode"] = Field(default_factory=list)
    asset_count: int = 0


# ---------------------------------------------------------------- assets
class AssetCreate(BaseModel):
    asset_no: str | None = Field(
        None, max_length=60, description="auto-generated when omitted"
    )
    name: str = Field(min_length=1, max_length=200)
    category_id: uuid.UUID | None = None
    model_name: str | None = Field(None, max_length=150)
    manufacturer: str | None = Field(None, max_length=150)
    serial_no: str | None = Field(None, max_length=150)
    barcode: str | None = Field(None, max_length=150)
    spec: str | None = None

    status: AssetStatus = AssetStatus.IN_STOCK
    location_id: uuid.UUID | None = None
    holder_id: uuid.UUID | None = None

    quantity: Decimal = Decimal(1)
    unit: str = Field("EA", max_length=20)
    min_quantity: Decimal | None = None

    purchase_date: date | None = None
    purchase_price: Decimal | None = None
    supplier: str | None = Field(None, max_length=150)
    warranty_until: date | None = None
    note: str | None = None


class AssetUpdate(BaseModel):
    """Location and holder changes should go through /move so history is kept."""

    name: str | None = Field(None, max_length=200)
    category_id: uuid.UUID | None = None
    model_name: str | None = Field(None, max_length=150)
    manufacturer: str | None = Field(None, max_length=150)
    serial_no: str | None = Field(None, max_length=150)
    barcode: str | None = Field(None, max_length=150)
    spec: str | None = None
    quantity: Decimal | None = None
    unit: str | None = Field(None, max_length=20)
    min_quantity: Decimal | None = None
    purchase_date: date | None = None
    purchase_price: Decimal | None = None
    supplier: str | None = Field(None, max_length=150)
    warranty_until: date | None = None
    note: str | None = None


class AssetOut(ORMModel):
    id: uuid.UUID
    asset_no: str
    name: str
    category_id: uuid.UUID | None = None
    model_name: str | None = None
    manufacturer: str | None = None
    serial_no: str | None = None
    barcode: str | None = None
    spec: str | None = None

    status: AssetStatus
    location_id: uuid.UUID | None = None
    holder_id: uuid.UUID | None = None

    quantity: Decimal
    unit: str
    min_quantity: Decimal | None = None

    purchase_date: date | None = None
    purchase_price: Decimal | None = None
    supplier: str | None = None
    warranty_until: date | None = None
    disposed_at: datetime | None = None
    note: str | None = None
    created_at: datetime
    updated_at: datetime


class AssetDetail(AssetOut):
    location: LocationOut | None = None
    holder: UserBrief | None = None
    category: CodeItemBrief | None = None
    is_below_min: bool = False


# ---------------------------------------------------------------- movements
class AssetMoveRequest(BaseModel):
    """The one write path for 위치 정리: updates the asset and logs the history."""

    movement_type: MovementType = MovementType.MOVE
    to_location_id: uuid.UUID | None = None
    to_holder_id: uuid.UUID | None = None
    to_status: AssetStatus | None = None
    quantity: Decimal | None = None
    moved_at: datetime | None = Field(None, description="defaults to now in UTC")
    reason: str | None = None
    reference_type: str | None = Field(None, max_length=60)
    reference_id: uuid.UUID | None = None


class AssetMovementOut(ORMModel):
    id: uuid.UUID
    asset_id: uuid.UUID
    movement_type: MovementType
    from_location_id: uuid.UUID | None = None
    to_location_id: uuid.UUID | None = None
    from_holder_id: uuid.UUID | None = None
    to_holder_id: uuid.UUID | None = None
    from_status: AssetStatus | None = None
    to_status: AssetStatus | None = None
    quantity: Decimal | None = None
    moved_at: datetime
    moved_by_id: uuid.UUID | None = None
    reason: str | None = None
    reference_type: str | None = None
    reference_id: uuid.UUID | None = None


# ---------------------------------------------------------------- summary
class CountBucket(BaseModel):
    key: str
    label: str
    count: int
    quantity: Decimal | None = None


class InventorySummary(BaseModel):
    total_assets: int
    total_quantity: Decimal
    total_value: Decimal | None = None
    by_status: list[CountBucket]
    by_category: list[CountBucket]
    by_location: list[CountBucket]
    below_min_count: int
    warranty_expiring_count: int = Field(description="warranty ends within 30 days")


LocationNode.model_rebuild()
