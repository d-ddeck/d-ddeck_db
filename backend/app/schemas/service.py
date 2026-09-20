"""서비스(AS) payloads, including the auto-statistics response shapes."""
from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, Field

from app.models.enums import ServiceChannel, ServicePriority, ServiceStatus
from app.schemas.common import ORMModel, UserBrief


# ---------------------------------------------------------------- customers
class CustomerCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    code: str | None = Field(None, max_length=60)
    contact_name: str | None = Field(None, max_length=80)
    phone: str | None = Field(None, max_length=50)
    email: str | None = Field(None, max_length=255)
    address: str | None = Field(None, max_length=300)
    note: str | None = None


class CustomerUpdate(BaseModel):
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
    quantity: Decimal = Decimal(1)
    unit_price: Decimal | None = None
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


class ServiceLogOut(ORMModel):
    id: uuid.UUID
    content: str | None = None
    work_minutes: int | None = None
    from_status: ServiceStatus | None = None
    to_status: ServiceStatus | None = None
    author_id: uuid.UUID | None = None
    created_at: datetime


# ---------------------------------------------------------------- tickets
class ServiceTicketCreate(BaseModel):
    title: str = Field(min_length=1, max_length=250)
    customer_id: uuid.UUID | None = None
    customer_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    site_address: str | None = Field(None, max_length=300)

    product_name: str | None = Field(None, max_length=150)
    model_name: str | None = Field(None, max_length=150)
    serial_no: str | None = Field(None, max_length=120)
    asset_id: uuid.UUID | None = None

    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    cause_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None

    priority: ServicePriority = ServicePriority.NORMAL
    channel: ServiceChannel = ServiceChannel.PHONE
    assignee_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None

    received_at: datetime | None = Field(None, description="defaults to now in UTC")
    due_at: datetime | None = None
    is_warranty: bool = True
    description: str | None = None
    parts: list[ServicePartIn] = Field(default_factory=list)


class ServiceTicketUpdate(BaseModel):
    """All optional: PATCH semantics. Status moves go through /status instead."""

    title: str | None = Field(None, max_length=250)
    customer_id: uuid.UUID | None = None
    customer_name: str | None = Field(None, max_length=150)
    contact_phone: str | None = Field(None, max_length=50)
    site_address: str | None = Field(None, max_length=300)
    product_name: str | None = Field(None, max_length=150)
    model_name: str | None = Field(None, max_length=150)
    serial_no: str | None = Field(None, max_length=120)
    asset_id: uuid.UUID | None = None
    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    cause_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None
    priority: ServicePriority | None = None
    channel: ServiceChannel | None = None
    assignee_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None
    due_at: datetime | None = None
    is_warranty: bool | None = None
    work_minutes: int | None = Field(None, ge=0)
    labor_cost: Decimal | None = None
    parts_cost: Decimal | None = None
    description: str | None = None
    result_note: str | None = None
    satisfaction: int | None = Field(None, ge=1, le=5)


class ServiceStatusChange(BaseModel):
    status: ServiceStatus
    note: str | None = None
    work_minutes: int | None = Field(None, ge=0)
    result_note: str | None = Field(None, description="required when moving to COMPLETED")


class ServiceTicketOut(ORMModel):
    id: uuid.UUID
    ticket_no: str
    title: str
    customer_id: uuid.UUID | None = None
    customer_name: str | None = None
    contact_phone: str | None = None
    site_address: str | None = None
    product_name: str | None = None
    model_name: str | None = None
    serial_no: str | None = None
    asset_id: uuid.UUID | None = None

    category_id: uuid.UUID | None = None
    symptom_id: uuid.UUID | None = None
    cause_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None

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

    description: str | None = None
    result_note: str | None = None
    satisfaction: int | None = None
    created_at: datetime
    updated_at: datetime


class ServiceTicketDetail(ServiceTicketOut):
    """List endpoints return ServiceTicketOut; detail adds the joined extras."""

    customer: CustomerOut | None = None
    assignee: UserBrief | None = None
    parts: list[ServicePartOut] = Field(default_factory=list)
    logs: list[ServiceLogOut] = Field(default_factory=list)
    resolution_minutes: int | None = None


# ---------------------------------------------------------------- statistics
class StatBucket(BaseModel):
    """One row of any grouped statistic.

    key is a stable identifier (enum value or code); label is for display.
    """

    key: str
    label: str
    color: str | None = None
    count: int
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
    period: str = Field(description="YYYY-MM-DD, YYYY-Www or YYYY-MM per interval")
    received: int
    completed: int


class ServiceTrend(BaseModel):
    interval: str
    points: list[TrendPoint]


class ServiceGrouped(BaseModel):
    group_by: str
    total: int
    buckets: list[StatBucket]
