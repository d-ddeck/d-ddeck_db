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
    # 매장에 나가 있는 장비. location_id 와 둘 중 하나는 있어야 한다.
    store_id: uuid.UUID | None = None
    set_no: int = Field(0, ge=0, description="매장 납품 세트 번호, 0 = 미지정")
    status_item_id: uuid.UUID | None = Field(
        None, description="세부 상태 코드(설치 / 렌탈 중 / AS 대기 ...)"
    )

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
    status_item_id: uuid.UUID | None = None


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
    store_id: uuid.UUID | None = None
    set_no: int = 0
    status_item_id: uuid.UUID | None = None

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
    store: "StoreBrief | None" = None
    status_item: CodeItemBrief | None = None
    is_below_min: bool = False


class StoreBrief(ORMModel):
    """자산 화면에서 "어느 매장에 있나"를 보여 줄 만큼만."""

    id: uuid.UUID
    name: str
    brand_id: uuid.UUID | None = None
    is_closed: bool = False


# ---------------------------------------------------------------- movements
class AssetMoveRequest(BaseModel):
    """The one write path for 위치 정리: updates the asset and logs the history."""

    movement_type: MovementType = MovementType.MOVE
    to_location_id: uuid.UUID | None = None
    to_holder_id: uuid.UUID | None = None
    to_status: AssetStatus | None = None
    # 매장으로 내보내거나 매장에서 거두어들일 때. 위치와 배타적이라,
    # 둘 중 하나를 채우면 반대쪽은 서버가 비운다.
    to_store_id: uuid.UUID | None = None
    to_set_no: int | None = Field(None, ge=0, description="매장 납품 세트 번호")
    to_status_item_id: uuid.UUID | None = Field(
        None, description="세부 상태 코드(설치 / 렌탈 중 / AS 대기 ...)"
    )
    clear_store: bool = Field(
        False, description="매장에서 거두어들일 때 true - 매장 연결을 끊는다"
    )
    quantity: Decimal | None = None
    moved_at: datetime | None = Field(None, description="defaults to now in UTC")
    reason: str | None = None
    reference_type: str | None = Field(None, max_length=60)
    reference_id: uuid.UUID | None = None


class AssetMovementOut(ORMModel):
    id: uuid.UUID
    asset_id: uuid.UUID
    movement_type: MovementType
    from_store_id: uuid.UUID | None = None
    to_store_id: uuid.UUID | None = None
    from_status_item_id: uuid.UUID | None = None
    to_status_item_id: uuid.UUID | None = None
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


# ---------------------------------------------------------------- 구 서버 재고 화면용
class AssetBulkCreate(BaseModel):
    """S/N 여러 개를 한 번에 등록 (구 서버 '입고·등록'). 나머지 칸은 공통."""

    serial_nos: list[str] = Field(min_length=1, description="S/N 목록. 공백·쉼표로 나눠 보내도 된다")
    name: str | None = Field(None, max_length=200, description="비우면 '종류 품명'")
    category_id: uuid.UUID | None = None
    model_name: str | None = Field(None, max_length=150)
    manufacturer: str | None = Field(None, max_length=150)
    status_item_id: uuid.UUID | None = None
    location_id: uuid.UUID | None = None
    store_id: uuid.UUID | None = None
    set_no: int = Field(0, ge=0)
    purchase_date: date | None = Field(None, description="설치일")
    note: str | None = None


class BulkCreateResult(BaseModel):
    created: list[AssetOut]
    duplicates: list[str] = Field(description="이미 있는 S/N 이라 건너뜀")


class AssetBulkMoveRequest(AssetMoveRequest):
    """목록에서 고른 장비 여러 대를 한 번에 옮기거나 상태만 바꿈 (한 대씩과 같은 규칙·같은 이력)."""

    asset_ids: list[uuid.UUID] = Field(min_length=1)


class BulkMoveResult(BaseModel):
    moved: list[str] = Field(description="옮긴 장비 (종류 S/N)")
    skipped: list[str] = Field(description="이미 그 상태·그 자리라 그대로 둔 장비")
    errors: list[str] = Field(default_factory=list)


class OverviewRow(BaseModel):
    key: str
    label: str
    color: str | None = None
    counts: dict[str, int] = Field(description="종류(category_id) -> 대수")
    total: int


class AttentionAsset(BaseModel):
    id: uuid.UUID
    asset_no: str
    name: str
    category_id: uuid.UUID | None = None
    category_name: str | None = None
    serial_no: str | None = None
    status_name: str | None = None
    store_id: uuid.UUID | None = None
    store_name: str | None = None
    location_name: str | None = None
    note: str | None = None


class RentalAsset(AttentionAsset):
    ticket_id: uuid.UUID | None = None
    ticket_no: str | None = None
    rented_at: datetime | None = None
    due_date: date | None = None
    dday: int | None = None


class InventoryOverview(BaseModel):
    """구 서버 재고 › 현황: 상태×종류 · 브랜드×종류(매장에 있는 것) · 장소×종류(미설치) · 확인 목록 · 렌탈 중."""

    total: int
    kinds: list[CodeItemBrief]
    statuses: list[CodeItemBrief]
    by_status: list[OverviewRow]
    by_brand: list[OverviewRow]
    by_place: list[OverviewRow]
    attention: list[AttentionAsset] = Field(description="AS 대기 · AS 반출 · 미상")
    rentals: list[RentalAsset]
