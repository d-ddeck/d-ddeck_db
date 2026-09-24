"""매장 요청/응답 스키마."""
from __future__ import annotations

import uuid
from datetime import date, datetime

from pydantic import BaseModel, Field

from app.schemas.common import CodeItemBrief, ORMModel


class StoreSetOut(ORMModel):
    id: uuid.UUID
    set_no: int
    name: str | None = None


class StoreCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    brand_id: uuid.UUID | None = None
    open_date: date | None = None
    is_closed: bool = False
    closed_date: date | None = None
    gripper_type: str | None = Field(None, max_length=20)
    note: str | None = None
    customer_id: uuid.UUID | None = None


class StoreUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=150)
    brand_id: uuid.UUID | None = None
    open_date: date | None = None
    is_closed: bool | None = None
    closed_date: date | None = None
    gripper_type: str | None = Field(None, max_length=20)
    note: str | None = None
    customer_id: uuid.UUID | None = None


class StoreOut(ORMModel):
    id: uuid.UUID
    name: str
    brand_id: uuid.UUID | None = None
    brand: CodeItemBrief | None = None
    open_date: date | None = None
    is_closed: bool
    closed_date: date | None = None
    gripper_type: str | None = None
    note: str | None = None
    created_at: datetime
    updated_at: datetime

    # 목록 화면이 매장마다 한 번 더 조회하지 않도록 같이 실어 보낸다.
    asset_count: int = 0
    ticket_count: int = 0


class AssetInStore(BaseModel):
    """매장 상세의 보유 장비 한 줄."""

    id: uuid.UUID
    asset_no: str
    name: str
    category: CodeItemBrief | None = None
    model_name: str | None = None
    serial_no: str | None = None
    status: str
    status_item: CodeItemBrief | None = None
    set_no: int = 0


class StoreAssetGroup(BaseModel):
    """보유 장비를 종류별로 묶은 것. 매장 화면이 종류 단위로 읽힌다."""

    category_id: uuid.UUID | None = None
    category_name: str
    color: str | None = None
    count: int
    assets: list[AssetInStore]


class StoreDetail(StoreOut):
    sets: list[StoreSetOut] = []
    asset_groups: list[StoreAssetGroup] = []


class BrandSummary(BaseModel):
    """브랜드별 매장·자산 현황. 재고 화면의 1차 분류."""

    brand_id: uuid.UUID | None = None
    brand_name: str
    color: str | None = None
    store_count: int
    open_store_count: int
    asset_count: int
