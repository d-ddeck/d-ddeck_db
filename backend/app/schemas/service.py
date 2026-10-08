"""서비스(AS) payloads, including the auto-statistics response shapes."""

from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import ClassVar, Literal

from pydantic import BaseModel, Field, field_serializer

from app.models.enums import ServiceChannel, ServicePriority, ServiceStatus
from app.schemas.common import CodeItemBrief, ORMModel, PatchModel, UserBrief


# ---------------------------------------------------------------- customers
class CustomerCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    code: str | None = Field(None, max_length=60)
    contact_name: str | None = Field(None, max_length=80)
    phone: str | None = Field(None, max_length=50)
    email: str | None = Field(None, max_length=255)
    address: str | None = Field(None, max_length=300)
    note: str | None = None


class CustomerUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {"name", "is_active"}

    name: str | None = Field(None, max_length=150)
    contact_name: str | None = Field(None, max_length=80)
    phone: str | None = Field(None, max_length=50)
    email: str | None = Field(None, max_length=255)
    address: str | None = Field(None, max_length=300)
    note: str | None = None
    is_active: bool | None = None


class CustomerOut(ORMModel):
    id: uuid.UUID
    name: str
    code: str | None = None
    contact_name: str | None = None
    phone: str | None = None
    email: str | None = None
    address: str | None = None
    is_active: bool
    created_at: datetime


# ---------------------------------------------------------------- parts / logs
class ServicePartIn(BaseModel):
    part_name: str = Field(min_length=1, max_length=150)
    quantity: Decimal = Field(default=Decimal(1), ge=0)
    unit_price: Decimal | None = Field(default=None, ge=0)
    asset_id: uuid.UUID | None = None
    note: str | None = None


class ServicePartOut(ORMModel):
    id: uuid.UUID
    part_name: str
    quantity: Decimal
    unit_price: Decimal | None = None
    asset_id: uuid.UUID | None = None
    note: str | None = None


class ServiceLogIn(BaseModel):
    content: str = Field(min_length=1)
    work_minutes: int | None = Field(None, ge=0)
    to_status: ServiceStatus | None = None


class ServiceLogUpdate(PatchModel):
    content: str | None = None
    work_minutes: int | None = Field(None, ge=0)


class ServiceLogOut(ORMModel):
    id: uuid.UUID
    content: str | None = None
    work_minutes: int | None = None
    from_status: ServiceStatus | None = None
    to_status: ServiceStatus | None = None
    author_id: uuid.UUID | None = None
    author: UserBrief | None = None
    created_at: datetime


# ---------------------------------------------------------------- 원인 (서비스구분 · 증상 · 제조사)
class CauseIn(BaseModel):
    """원인 한 쌍. 구 서버의 (서비스구분, 세부분류, 제조사).

    로봇팔 · 제어박스 · 전동 그리퍼(설정 `maker_required_categories`)는 제조사가
    필수다. 증상은 그 서비스구분에 딸린 것이어야 한다.
    """

    category_id: uuid.UUID
    symptom_id: uuid.UUID | None = None
    maker_id: uuid.UUID | None = None


class CauseOut(ORMModel):
    id: uuid.UUID
    seq: int
    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    maker_id: uuid.UUID | None = None
    category: CodeItemBrief | None = None
    symptom: CodeItemBrief | None = None
    maker: CodeItemBrief | None = None


class StoreRef(ORMModel):
    """접수 화면이 매장으로 건너갈 만큼만."""

    id: uuid.UUID
    name: str
    brand_id: uuid.UUID | None = None
    brand_name: str | None = None
    is_closed: bool = False


# ---------------------------------------------------------------- tickets
class _RentalFields(BaseModel):
    # 구 서버 규칙: 렌탈 O 면 종류 · 시리얼(재고 S/N) · 회수 예정일 필수,
    # 회수 O 면 실제 회수일 필수. 서버가 검사한다.
    is_rental: bool | None = None
    rental_type_id: uuid.UUID | None = None
    rental_serials: str | None = Field(
        None, max_length=300, description="쉼표 구분 S/N"
    )
    rental_due_date: date | None = None
    rental_returned: bool | None = None
    rental_return_date: date | None = None


class ServiceTicketCreate(_RentalFields):
    initial_status: Literal["RECEIVED", "IN_PROGRESS", "COMPLETED"] | None = None
    note: str | None = Field(None, max_length=10000)
    result_note: str | None = None
    completed_at: datetime | None = Field(
        None, description="initial_status=COMPLETED 일 때 대응일. 비우면 지금"
    )
    title: str = Field(min_length=1, max_length=250)
    customer_id: uuid.UUID | None = None
    customer_name: str | None = Field(None, max_length=150)
    contact_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    site_address: str | None = Field(None, max_length=300)
    # 매장 - 구 서버의 브랜드 → 매장. 브랜드는 매장에서 따라온다.
    store_id: uuid.UUID | None = None

    product_name: str | None = Field(None, max_length=150)
    model_name: str | None = Field(None, max_length=150)
    serial_no: str | None = Field(None, max_length=120)
    asset_id: uuid.UUID | None = None

    work_type_id: uuid.UUID | None = None
    # 대표 분류. `causes` 를 보내면 그 첫 항목으로 덮어쓴다.
    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    cause_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None
    fault_id: uuid.UUID | None = Field(None, description="과실")
    # 원인 여러 개 (최대 `max_causes`, 기본 10). 첫 항목이 대표 분류가 된다.
    causes: list[CauseIn] | None = None
    # 대응인원 (SERVICE_RESPONDER 코드 항목)
    responder_ids: list[uuid.UUID] | None = None

    priority: ServicePriority = ServicePriority.NORMAL
    channel: ServiceChannel = ServiceChannel.PHONE
    assignee_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None

    received_at: datetime | None = Field(None, description="발생일시. 비우면 지금(UTC)")
    due_at: datetime | None = None
    is_warranty: bool = True
    description: str | None = None
    parts: list[ServicePartIn] = Field(default_factory=list)

    is_rental: bool = False


class ServiceTicketUpdate(_RentalFields, PatchModel):
    non_nullable = {
        "is_rental",
        "rental_returned",
        "is_warranty",
        "priority",
        "received_at",
        "channel",
        "title",
    }

    """All optional: PATCH semantics. Status moves go through /status instead."""

    title: str | None = Field(None, max_length=250)
    customer_id: uuid.UUID | None = None
    customer_name: str | None = Field(None, max_length=150)
    contact_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    site_address: str | None = Field(None, max_length=300)
    store_id: uuid.UUID | None = None
    product_name: str | None = Field(None, max_length=150)
    model_name: str | None = Field(None, max_length=150)
    serial_no: str | None = Field(None, max_length=120)
    asset_id: uuid.UUID | None = None
    work_type_id: uuid.UUID | None = None
    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    cause_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None
    fault_id: uuid.UUID | None = None
    causes: list[CauseIn] | None = None
    responder_ids: list[uuid.UUID] | None = None
    priority: ServicePriority | None = None
    channel: ServiceChannel | None = None
    assignee_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None
    received_at: datetime | None = None
    due_at: datetime | None = None
    is_warranty: bool | None = None
    work_minutes: int | None = Field(None, ge=0)
    labor_cost: Decimal | None = Field(default=None, ge=0)
    parts_cost: Decimal | None = Field(default=None, ge=0)
    description: str | None = None
    result_note: str | None = None
    satisfaction: int | None = Field(None, ge=1, le=5)


class ServiceStatusChange(BaseModel):
    status: ServiceStatus
    note: str | None = None
    work_minutes: int | None = Field(None, ge=0)
    result_note: str | None = Field(
        None, description="required when moving to COMPLETED"
    )
    # 종결(COMPLETED)에는 대응인원이 있어야 한다(설정 require_responder_on_complete).
    # 아직 없으면 여기서 같이 보낸다.
    responder_ids: list[uuid.UUID] | None = None
    completed_at: datetime | None = Field(None, description="대응일. 비우면 지금")


class ServiceTicketOut(ORMModel):
    id: uuid.UUID
    ticket_no: str
    legacy_no: int | None = None

    @field_serializer("legacy_no")
    def display_legacy_no(self, value: int | None) -> int | None:
        # Older Windows/Android clients prefer legacy_no over ticket_no.
        # Retain the original in the DB, but stop overriding a reissued number.
        return value if value is not None and self.ticket_no == str(value) else None

    title: str
    customer_id: uuid.UUID | None = None
    customer_name: str | None = None
    contact_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = None
    site_address: str | None = None
    store_id: uuid.UUID | None = None
    product_name: str | None = None
    model_name: str | None = None
    serial_no: str | None = None
    asset_id: uuid.UUID | None = None

    work_type_id: uuid.UUID | None = None
    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    cause_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None
    fault_id: uuid.UUID | None = None

    status: ServiceStatus
    priority: ServicePriority
    channel: ServiceChannel
    assignee_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None

    received_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None
    due_at: datetime | None = None

    is_warranty: bool
    work_minutes: int | None = None
    labor_cost: Decimal | None = None
    parts_cost: Decimal | None = None
    total_cost: Decimal | None = None

    is_rental: bool = False
    rental_type_id: uuid.UUID | None = None
    rental_serials: str | None = None
    rental_due_date: date | None = None
    rental_returned: bool = False
    rental_return_date: date | None = None

    description: str | None = None
    result_note: str | None = None
    satisfaction: int | None = None
    created_at: datetime
    updated_at: datetime

    # 목록에서도 원인 · 대응인원을 한 줄로 보여 줄 수 있게 이름만 실어 보낸다.
    work_type: CodeItemBrief | None = None
    cause_labels: list[str] = Field(default_factory=list)
    responder_names: list[str] = Field(default_factory=list)
    store_name: str | None = None
    brand_name: str | None = None
    attachment_count: int = 0
    log_count: int = 0


class ServiceTicketDetail(ServiceTicketOut):
    """List endpoints return ServiceTicketOut; detail adds the joined extras."""

    customer: CustomerOut | None = None
    store: StoreRef | None = None
    assignee: UserBrief | None = None
    fault: CodeItemBrief | None = None
    rental_type: CodeItemBrief | None = None
    # ORM 의 같은 이름 관계(원인 행 · 대응인원 행)를 그대로 읽지 않도록 별칭을 둔다.
    # _detail() 이 코드 이름을 붙여 채운다.
    causes: list[CauseOut] = Field(default_factory=list, validation_alias="causes_out")
    responders: list[CodeItemBrief] = Field(
        default_factory=list, validation_alias="responders_out"
    )
    parts: list[ServicePartOut] = Field(default_factory=list)
    logs: list[ServiceLogOut] = Field(default_factory=list)
    resolution_minutes: int | None = None
    # 저장하면서 재고에 한 일(렌탈 중 ↔ 창고). 화면이 그대로 보여 준다.
    notices: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------- statistics
class StatBucket(BaseModel):
    """One row of any grouped statistic.

    key is a stable identifier (enum value or code); label is for display.
    """

    key: str
    label: str
    color: str | None = None
    count: int
    # On a 분류 axis this is 원인 수, not 대응 건수: one 건 filed under three
    # 서비스구분 counts once in each. `ticket_count` is the de-duplicated
    # number. The previous server showed both columns side by side and so
    # should any screen built on this.
    ticket_count: int | None = Field(
        None, description="distinct tickets behind this bucket (multi-value axes only)"
    )
    ratio: float = Field(description="share of the total, 0.0 to 1.0")
    avg_resolution_minutes: float | None = None
    total_cost: Decimal | None = None


class ServiceSummary(BaseModel):
    date_from: datetime | None = None
    date_to: datetime | None = None
    total: int
    open_count: int
    completed_count: int
    canceled_count: int
    overdue_count: int
    completion_rate: float
    avg_resolution_minutes: float | None = None
    avg_satisfaction: float | None = None
    total_cost: Decimal | None = None
    by_status: list[StatBucket]
    by_priority: list[StatBucket]


class TrendPoint(BaseModel):
    period: str = Field(
        description="YYYY-MM-DD, YYYY-Www, YYYY-MM or YYYY per interval"
    )
    received: int
    completed: int


class ServiceTrend(BaseModel):
    interval: str
    points: list[TrendPoint]


class ServiceGrouped(BaseModel):
    tickets_without_cause: int = 0
    group_by: str
    total: int = Field(description="대응 건수 - tickets matching the filters")
    # Set on multi-value axes (분류 / 증상 / 제조사). It is the denominator of
    # `ratio` there, because a 건 with three 분류 contributes three rows.
    total_causes: int | None = Field(
        None, description="원인 수 - classification rows behind those tickets"
    )
    buckets: list[StatBucket]


class AxisKey(BaseModel):
    key: str
    label: str
    color: str | None = None


class CrosstabRow(BaseModel):
    key: str
    label: str
    color: str | None = None
    cells: dict[str, int] = Field(description="열 key -> 원인 수")
    total: int
    ticket_count: int = Field(description="이 줄에 걸린 대응 건수(중복 제거)")
    ratio: float = Field(description="전체 원인 수 대비 비율, 0.0~1.0")


class Crosstab(BaseModel):
    tickets_without_cause: int = 0
    """구 서버 통계의 표 하나: 행 축 × 열 축, 칸은 원인 수.

    한 건에 원인이 여러 개면 각각 센다(구 서버와 같다). 그래서 칸 합은 대응
    건수보다 클 수 있고, `total_tickets` 를 옆에 같이 보여 줘야 한다.
    """

    rows_axis: str
    cols_axis: str
    cols: list[AxisKey]
    rows: list[CrosstabRow]
    col_totals: dict[str, int]
    total_causes: int
    total_tickets: int


class StoreYearRow(BaseModel):
    year: str
    operating: int = Field(description="그 해에 운영된 매장 수")
    opened: int = Field(description="그 해 개점(또는 첫 확인)")
    closed: int = Field(description="그 해 미운영")
    year_end: int = Field(description="연말 운영 매장")
    active: int = Field(description="대응이 발생한 매장 수")
    tickets: int = Field(description="대응 건수")
    per_store: float | None = Field(None, description="매장당 건수")


class BrandYearRow(BaseModel):
    brand: str
    counts: dict[str, int]


class StoreYears(BaseModel):
    years: list[str]
    rows: list[StoreYearRow]
    by_brand: list[BrandYearRow]
    total_stores: int
    closed_stores: int
    unknown_open: list[str] = Field(description="개점 연도를 알 수 없는 매장")


class ResponderYearRow(BaseModel):
    name: str
    counts: dict[str, int] = Field(description="연도 -> 대응 건수")
    total: int


class ResponderYears(BaseModel):
    """연도별 대응인원. 한 건에 여러 명이 나가면 사람마다 한 건씩 센다."""

    years: list[str]
    rows: list[ResponderYearRow]


# ---------------------------------------------------------------- dashboard (구 서버 첫 화면)
class TicketBrief(BaseModel):
    id: uuid.UUID
    ticket_no: str
    title: str
    store_name: str | None = None
    brand_name: str | None = None
    status: ServiceStatus
    received_at: datetime
    days_open: int | None = None


class RentalRow(BaseModel):
    ticket_id: uuid.UUID
    ticket_no: str
    store_name: str | None = None
    rental_type: str | None = None
    serials: str | None = None
    due_date: date | None = None
    dday: int | None = Field(None, description="회수 예정일까지 남은 날. 음수면 지남")


class YearCount(BaseModel):
    year: str
    count: int


class ServiceDashboard(BaseModel):
    total: int
    this_year: int
    open_count: int
    open_tickets: list[TicketBrief] = Field(description="미종결, 오래된 것부터")
    unreturned_rentals: list[RentalRow]
    recent: list[ServiceTicketOut] = Field(description="최근 등록·수정 순")
    by_year: list[YearCount]
