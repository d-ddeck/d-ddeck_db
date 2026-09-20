"""캘린더 module: shared schedules, participants, reminders, notifications."""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    Boolean,
    ForeignKey,
    Integer,
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
    JSONType,
    SoftDeleteMixin,
    TimestampMixin,
    UUIDMixin,
    enum_type,
)
from app.models.enums import (
    CalendarType,
    EventStatus,
    NotificationType,
    ParticipantResponse,
    ReminderMethod,
)


class Calendar(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    """A schedule container. PERSONAL is private by default; DEPARTMENT and
    COMPANY are the shared ones everyone sees."""

    __tablename__ = "calendars"

    name: Mapped[str] = mapped_column(String(120), nullable=False)
    type: Mapped[CalendarType] = mapped_column(
        enum_type(CalendarType), default=CalendarType.PERSONAL, nullable=False, index=True
    )
    color: Mapped[str] = mapped_column(String(20), default="#3B82F6", nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    owner_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    department_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("departments.id", ondelete="CASCADE"), index=True
    )
    is_shared: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    # Defaults the 캘린더 설정창 applies to new events on this calendar.
    default_reminder_minutes: Mapped[int | None] = mapped_column(Integer, default=30)

    events: Mapped[list["Event"]] = relationship(back_populates="calendar")


class Event(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "events"

    calendar_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("calendars.id", ondelete="CASCADE"), nullable=False, index=True
    )
    title: Mapped[str] = mapped_column(String(250), nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    location: Mapped[str | None] = mapped_column(String(250))
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL"), index=True
    )

    # Stored in UTC; the client renders in the device timezone.
    starts_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, index=True
    )
    ends_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, index=True
    )
    all_day: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Seoul", nullable=False)

    # RFC 5545 RRULE string, e.g. "FREQ=WEEKLY;BYDAY=MO,WE".
    # Skeleton stores it; expansion into occurrences is a later step.
    rrule: Mapped[str | None] = mapped_column(String(250))
    recurrence_end: Mapped[datetime | None] = mapped_column(UTCDateTime)

    status: Mapped[EventStatus] = mapped_column(
        enum_type(EventStatus), default=EventStatus.SCHEDULED, nullable=False, index=True
    )
    color: Mapped[str | None] = mapped_column(String(20))
    is_private: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Optional links back to the other modules.
    service_ticket_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("service_tickets.id", ondelete="SET NULL")
    )

    calendar: Mapped["Calendar"] = relationship(back_populates="events")
    participants: Mapped[list["EventParticipant"]] = relationship(
        back_populates="event", cascade="all, delete-orphan"
    )
    reminders: Mapped[list["EventReminder"]] = relationship(
        back_populates="event", cascade="all, delete-orphan"
    )


class EventParticipant(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "event_participants"
    __table_args__ = (UniqueConstraint("event_id", "user_id", name="uq_event_participant"),)

    event_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("events.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    is_organizer: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_required: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    response: Mapped[ParticipantResponse] = mapped_column(
        enum_type(ParticipantResponse), default=ParticipantResponse.PENDING, nullable=False
    )
    responded_at: Mapped[datetime | None] = mapped_column(UTCDateTime)

    event: Mapped["Event"] = relationship(back_populates="participants")


class EventReminder(UUIDMixin, TimestampMixin, Base):
    """One reminder rule per row.

    `scheduled_at` is precomputed (starts_at - offset) so the scheduler can find
    what is due with a single indexed range scan instead of recomputing offsets.
    """

    __tablename__ = "event_reminders"

    event_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("events.id", ondelete="CASCADE"), nullable=False, index=True
    )
    offset_minutes: Mapped[int] = mapped_column(Integer, default=30, nullable=False)
    method: Mapped[ReminderMethod] = mapped_column(
        enum_type(ReminderMethod), default=ReminderMethod.PUSH, nullable=False
    )
    scheduled_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, index=True
    )
    sent_at: Mapped[datetime | None] = mapped_column(UTCDateTime, index=True)

    event: Mapped["Event"] = relationship(back_populates="reminders")


class Notification(UUIDMixin, TimestampMixin, Base):
    """One row per recipient. The client polls unread, and push mirrors it."""

    __tablename__ = "notifications"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    type: Mapped[NotificationType] = mapped_column(
        enum_type(NotificationType), nullable=False, index=True
    )
    title: Mapped[str] = mapped_column(String(250), nullable=False)
    body: Mapped[str | None] = mapped_column(Text)
    # Deep-link target for the Flutter client, e.g. {"route": "/event", "id": "..."}
    payload: Mapped[Any] = mapped_column(JSONType, nullable=True)
    entity_type: Mapped[str | None] = mapped_column(String(60))
    entity_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)

    is_read: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    read_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    pushed_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
