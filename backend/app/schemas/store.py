"""매장 요청/응답 스키마."""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import ClassVar

from pydantic import BaseModel, Field

from app.schemas.common import CodeItemBrief, ORMModel, PatchModel


class StoreSetOut(ORMModel):
    id: uuid.UUID
    set_no: int
    name: str | None = None


class StoreCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    brand_id: uuid.UUID | None = None
    open_date: date | None = None
    is_active: bool = True
    is_closed: bool = False
    closed_date: date | None = None
    gripper_type: str | None = Field(None, max_length=20)
    contact_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    address: str | None = Field(None, max_length=300)
    note: str | None = None
    customer_id: uuid.UUID | None = None


class StoreUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {"name", "is_closed", "is_active"}

    name: str | None = Field(None, min_length=1, max_length=150)
    # 폐점(is_closed=true)으로 저장하면서 설치 장비를 보낼 상태. 비우면 장비는 그대로.
    recover_to_status_item_id: uuid.UUID | None = None
    brand_id: uuid.UUID | None = None
    open_date: date | None = None
    is_active: bool | None = None
    is_closed: bool | None = None
    closed_date: date | None = None
    gripper_type: str | None = Field(None, max_length=20)
    contact_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    address: str | None = Field(None, max_length=300)
    note: str | None = None
    customer_id: uuid.UUID | None = None


class StoreOut(ORMModel):
    id: uuid.UUID
    name: str
    brand_id: uuid.UUID | None = None
    brand: CodeItemBrief | None = None
    open_date: date | None = None
    is_active: bool
    is_closed: bool
    closed_date: date | None = None
    gripper_type: str | None = None
    contact_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    address: str | None = Field(None, max_length=300)
    note: str | None = None
    created_at: datetime
    updated_at: datetime

    # 목록 화면이 매장마다 한 번 더 조회하지 않도록 같이 실어 보낸다.
    asset_count: int = 0
    ticket_count: int = 0
    last_ticket_at: datetime | None = None
    open_ticket_count: int = 0


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


class BrandSummary(BaseModel):
    """브랜드별 매장·자산 현황. 재고 화면의 1차 분류."""

    brand_id: uuid.UUID | None = None
    brand_name: str
    color: str | None = None
    store_count: int
    open_store_count: int
    asset_count: int
    ticket_count: int = 0
    open_ticket_count: int = 0


# ---------------------------------------------------------------- 구 서버 매장 화면용
class StoreTicketBrief(BaseModel):
    id: uuid.UUID
    ticket_no: str
    title: str
    status: str
    received_at: datetime
    completed_at: datetime | None = None
    cause_labels: list[str] = []


class StoreRentalRow(BaseModel):
    ticket_id: uuid.UUID
    ticket_no: str
    rental_type: str | None = None
    serials: str | None = None
    due_date: date | None = None
    dday: int | None = None


class CategoryCount(BaseModel):
    category_id: uuid.UUID | None = None
    label: str
    color: str | None = None
    count: int


class StoreDetail(StoreOut):
    notices: list[str] = Field(default_factory=list)
    sets: list[StoreSetOut] = Field(default_factory=list)
    asset_groups: list[StoreAssetGroup] = Field(default_factory=list)
    # 구 서버 매장 화면의 나머지: 서비스구분별 발생 · 미회수 렌탈 · 대응 이력 · 폐점 회수 안내
    open_ticket_count: int = 0
    install_date: date | None = Field(None, description="보유 장비 중 가장 이른 설치일")
    category_counts: list[CategoryCount] = Field(
        default_factory=list, description="서비스구분별 원인 수"
    )
    unreturned_rentals: list[StoreRentalRow] = Field(default_factory=list)
    recent_tickets: list[StoreTicketBrief] = Field(default_factory=list)
    recover_options: list[CodeItemBrief] = Field(
        default_factory=list,
        description="폐점 때 장비를 보낼 수 있는 상태. 첫 항목이 기본값",
    )
    movable_count: int = Field(
        0, description="폐점 때 회수될 장비 수 (설치 · AS 대기 · AS 반출)"
    )
    rental_count: int = Field(0, description="렌탈 중 장비 수 - 폐점 때 옮기지 않음")


class StoreCloseRequest(BaseModel):
    """폐점 처리. 설치 장비를 고른 상태로 옮긴다 (구 서버 recover_closed_store_assets).

    recover_to_status_item_id 가 비어 있으면 장비는 그대로 두고 남은 수만 알려 준다.
    """

    closed_date: date | None = None
    recover_to_status_item_id: uuid.UUID | None = None
    note: str | None = None


class StoreCloseResult(BaseModel):
    store: StoreDetail
    moved: list[str] = Field(description="옮긴 장비 (종류 S/N)")
    notices: list[str] = Field(default_factory=list)


class StoreSetIn(BaseModel):
    name: str | None = Field(None, max_length=80)


class EquipmentSlotIn(BaseModel):
    """세트의 장비 한 칸: 종류 + S/N (+ 품명 · 제조사). S/N 이 없는 칸은 건너뛴다."""

    category_id: uuid.UUID
    serial_no: str | None = Field(None, max_length=150)
    model_name: str | None = Field(None, max_length=150)
    manufacturer: str | None = Field(None, max_length=150)


class EquipmentSetIn(BaseModel):
    set_no: int | None = Field(None, ge=1, description="비우면 순서대로 1, 2, …")
    name: str | None = Field(None, max_length=80)
    gripper_type: str = Field(description="전동 / 비전동")
    note: str | None = None
    slots: list[EquipmentSlotIn] = Field(default_factory=list)


class EquipmentSetupRequest(BaseModel):
    """매장 장비 설정 (구 서버 store_equipment): 납품 세트 여러 개의 S/N 을 한 화면에서.

    - 없는 S/N 은 이 매장에 '설치'로 새로 등록, 다른 곳에 있던 장비는 이 매장으로 이동,
      이미 이 매장에 있으면 세트 번호만 맞춘다.
    - 비전동 세트에 비전동 그리퍼 S/N 이 없으면 관리 번호(NG-0001 …)를 붙여 재고에 넣는다.
    """

    install_date: date | None = None
    sets: list[EquipmentSetIn] = Field(min_length=1)


class EquipmentSetupResult(BaseModel):
    added: list[str]
    moved: list[str]
    kept: list[str]
    store: StoreDetail
