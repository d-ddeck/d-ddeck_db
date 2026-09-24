"""서비스(AS) module.

Classification is deliberately split into four CodeItem FKs
(category / symptom / cause / action) because that is exactly the breakdown the
auto-statistics screen groups by.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime

from sqlalchemy import (
    Boolean,
    Date,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
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
    # 구 서버(CS_Record)의 기록 번호. Migrated tickets keep their old number as
    # ticket_no as well - the team refers to 건 by that number - and this column
    # marks which rows came across so a re-run can find them again.
    legacy_no: Mapped[int | None] = mapped_column(Integer, unique=True, index=True)
    title: Mapped[str] = mapped_column(String(250), nullable=False)

    # --- who / where ---
    customer_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )
    customer_name: Mapped[str | None] = mapped_column(String(150))  # walk-in, no master row
    contact_phone: Mapped[str | None] = mapped_column(String(50))
    site_address: Mapped[str | None] = mapped_column(String(300))
    # 매장 - the site the equipment is installed at. Distinct from customer_id:
    # a brand can be the customer while the ticket happened at one of its stores.
    store_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("stores.id", ondelete="SET NULL"), index=True
    )

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
    # 과실 - attribution (자체 충돌 / 사용자 오조작 / 제품 불량 ...). A separate
    # axis from cause_id: "whose fault" and "what broke" are different answers.
    fault_id: Mapped[uuid.UUID | None] = mapped_column(
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

    # --- 렌탈: equipment lent to the site while theirs is being repaired ---
    # The old server drove 재고 status from these fields (렌탈 중 <-> 창고). That
    # automation is not wired up yet; these hold the record so it can be.
    is_rental: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    rental_type_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL")
    )
    rental_serials: Mapped[str | None] = mapped_column(String(300))  # 쉼표 구분 S/N
    rental_due_date: Mapped[date | None] = mapped_column(Date)       # 회수 예정일
    rental_returned: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    rental_return_date: Mapped[date | None] = mapped_column(Date)    # 실제 회수일

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
    causes: Mapped[list["ServiceTicketCause"]] = relationship(
        back_populates="ticket",
        cascade="all, delete-orphan",
        order_by="ServiceTicketCause.seq",
    )
    responders: Mapped[list["ServiceTicketResponder"]] = relationship(
        back_populates="ticket",
        cascade="all, delete-orphan",
        order_by="ServiceTicketResponder.seq",
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

class ServiceTicketCause(UUIDMixin, TimestampMixin, Base):
    """분류 하나. A ticket has one row per 서비스구분 it was filed under.

    The four `*_id` columns on ServiceTicket stay as the ticket's headline
    classification (they are what the existing statistics group by). This table
    is the full list: the previous server recorded up to 10 per 건, and 97 of
    its 566 records carry two or three.

    Note for whoever wires statistics onto this: the old server counted these
    rows, not tickets, so a 3-cause 건 landed in three buckets and the screen
    showed 원인 수 and 대응 건수 side by side. Counting tickets and counting
    causes are different numbers and the UI has to say which one it means.
    """

    __tablename__ = "service_ticket_causes"
    __table_args__ = (UniqueConstraint("ticket_id", "seq", name="uq_ticket_cause_seq"),)

    ticket_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("service_tickets.id", ondelete="CASCADE"), nullable=False, index=True
    )
    seq: Mapped[int] = mapped_column(Integer, nullable=False)

    # 서비스구분 (로봇팔 / 제어박스 / 통신 ...) -> SERVICE_CATEGORY
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )
    # 세부구분 -> SERVICE_SYMPTOM (증상). The old server stored this as the
    # composite string "제어박스 > 파워 케이블" inside one list; here it is a
    # symptom code whose parent_id points at the category above, so renaming a
    # category cannot desync the prefix.
    symptom_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )
    # 제조사 - required on 로봇팔 / 제어박스 / 전동 그리퍼 in the old system.
    maker_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    ticket: Mapped["ServiceTicket"] = relationship(back_populates="causes")


class ServiceTicketResponder(UUIDMixin, TimestampMixin, Base):
    """대응인원. Up to three people went out on one 건.

    Deliberately a CodeItem and not a user: the master list holds people who
    never had an account (이선희 alone appears on 106 records) alongside entries
    that are not individuals at all (CS팀, 레인보우CS팀, 대표님). Where a
    responder does have an account, the CodeItem carries the user id in `extra`.

    `assignee_id` on the ticket remains the single owning assignee.
    """

    __tablename__ = "service_ticket_responders"
    __table_args__ = (UniqueConstraint("ticket_id", "seq", name="uq_ticket_responder_seq"),)

    ticket_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("service_tickets.id", ondelete="CASCADE"), nullable=False, index=True
    )
    seq: Mapped[int] = mapped_column(Integer, nullable=False)
    responder_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    ticket: Mapped["ServiceTicket"] = relationship(back_populates="responders")
