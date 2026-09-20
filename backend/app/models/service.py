"""서비스(AS) module.

Classification is deliberately split into four CodeItem FKs
(category / symptom / cause / action) because that is exactly the breakdown the
auto-statistics screen groups by.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import (
    UTCDateTime,
    AuthorMixin,
    Base,
    SoftDeleteMixin,
    TimestampMixin,
    UUIDMixin,
    enum_type,
)
from app.models.enums import ServiceChannel, ServicePriority, ServiceStatus


class Customer(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "customers"

    name: Mapped[str] = mapped_column(String(150), nullable=False, index=True)
    code: Mapped[str | None] = mapped_column(String(60), unique=True)
    contact_name: Mapped[str | None] = mapped_column(String(80))
    phone: Mapped[str | None] = mapped_column(String(50))
    email: Mapped[str | None] = mapped_column(String(255))
    address: Mapped[str | None] = mapped_column(String(300))
    note: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)


class ServiceTicket(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "service_tickets"

    ticket_no: Mapped[str] = mapped_column(String(40), unique=True, index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(250), nullable=False)

    # --- who / where ---
    customer_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )
    customer_name: Mapped[str | None] = mapped_column(String(150))  # walk-in, no master row
    contact_phone: Mapped[str | None] = mapped_column(String(50))
    site_address: Mapped[str | None] = mapped_column(String(300))

    # --- what ---
    product_name: Mapped[str | None] = mapped_column(String(150))
    model_name: Mapped[str | None] = mapped_column(String(150))
    serial_no: Mapped[str | None] = mapped_column(String(120), index=True)
    asset_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("assets.id", ondelete="SET NULL")
    )  # when the serviced unit is our own asset

    # --- classification: the statistics axes ---
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )
    symptom_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )
    cause_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )
    action_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    # --- workflow ---
    status: Mapped[ServiceStatus] = mapped_column(
        enum_type(ServiceStatus), default=ServiceStatus.RECEIVED, nullable=False, index=True
    )
    priority: Mapped[ServicePriority] = mapped_column(
        enum_type(ServicePriority), default=ServicePriority.NORMAL, nullable=False, index=True
    )
    channel: Mapped[ServiceChannel] = mapped_column(
        enum_type(ServiceChannel), default=ServiceChannel.PHONE, nullable=False
    )
    assignee_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    department_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("departments.id", ondelete="SET NULL"), index=True
    )

    # --- timeline: every stat about duration reads these three ---
    received_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, index=True
    )
    started_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    completed_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime, index=True
    )
    due_at: Mapped[datetime | None] = mapped_column(UTCDateTime)

    # --- cost ---
    is_warranty: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False, index=True)
    work_minutes: Mapped[int | None] = mapped_column(Integer)
    labor_cost: Mapped[float | None] = mapped_column(Numeric(14, 2))
    parts_cost: Mapped[float | None] = mapped_column(Numeric(14, 2))
    total_cost: Mapped[float | None] = mapped_column(Numeric(14, 2))

    # --- content ---
    description: Mapped[str | None] = mapped_column(Text)   # 접수 내용
    result_note: Mapped[str | None] = mapped_column(Text)   # 처리 결과
    satisfaction: Mapped[int | None] = mapped_column(Integer)  # 1-5

    customer: Mapped["Customer | None"] = relationship()
    parts: Mapped[list["ServicePart"]] = relationship(
        back_populates="ticket", cascade="all, delete-orphan"
    )
    logs: Mapped[list["ServiceLog"]] = relationship(
        back_populates="ticket", cascade="all, delete-orphan", order_by="ServiceLog.created_at"
    )

    @property
    def is_open(self) -> bool:
        return self.status not in (ServiceStatus.COMPLETED, ServiceStatus.CANCELED)

    @property
    def resolution_minutes(self) -> int | None:
        if not self.completed_at:
            return None
        return int((self.completed_at - self.received_at).total_seconds() // 60)


class ServicePart(UUIDMixin, TimestampMixin, Base):
    """Parts consumed on a ticket. Links 서비스 <-> 재고 so stock can be drawn down."""

    __tablename__ = "service_parts"

    ticket_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("service_tickets.id", ondelete="CASCADE"), nullable=False, index=True
    )
    asset_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("assets.id", ondelete="SET NULL")
    )
    part_name: Mapped[str] = mapped_column(String(150), nullable=False)
    quantity: Mapped[float] = mapped_column(Numeric(12, 3), default=1, nullable=False)
    unit_price: Mapped[float | None] = mapped_column(Numeric(14, 2))
    note: Mapped[str | None] = mapped_column(Text)

    ticket: Mapped["ServiceTicket"] = relationship(back_populates="parts")


class ServiceLog(UUIDMixin, TimestampMixin, Base):
    """Per-ticket work journal and status history."""

    __tablename__ = "service_logs"

    ticket_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("service_tickets.id", ondelete="CASCADE"), nullable=False, index=True
    )
    author_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    from_status: Mapped[ServiceStatus | None] = mapped_column(enum_type(ServiceStatus))
    to_status: Mapped[ServiceStatus | None] = mapped_column(enum_type(ServiceStatus))
    content: Mapped[str | None] = mapped_column(Text)
    work_minutes: Mapped[int | None] = mapped_column(Integer)

    ticket: Mapped["ServiceTicket"] = relationship(back_populates="logs")
