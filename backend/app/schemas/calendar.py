"""캘린더 payloads: calendars, events, participants, reminders, notifications."""
from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, model_validator

from app.models.enums import (
    CalendarType,
    EventStatus,
    NotificationType,
    ParticipantResponse,
    ReminderMethod,
)
from app.schemas.common import ORMModel, UserBrief


# ---------------------------------------------------------------- calendars
class CalendarCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    type: CalendarType = CalendarType.PERSONAL
    color: str = Field("#3B82F6", max_length=20)
    description: str | None = None
    department_id: uuid.UUID | None = None
    is_shared: bool = False
    default_reminder_minutes: int | None = Field(30, ge=0, le=20160)


class CalendarUpdate(BaseModel):
    name: str | None = Field(None, max_length=120)
    color: str | None = Field(None, max_length=20)
    description: str | None = None
    department_id: uuid.UUID | None = None
    is_shared: bool | None = None
    is_active: bool | None = None
    default_reminder_minutes: int | None = Field(None, ge=0, le=20160)


class CalendarOut(ORMModel):
    id: uuid.UUID
    name: str
    type: CalendarType
    color: str
    description: str | None = None
    owner_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None
    is_shared: bool
    is_active: bool
    default_reminder_minutes: int | None = None
    created_at: datetime


# ---------------------------------------------------------------- reminders
class ReminderIn(BaseModel):
    offset_minutes: int = Field(30, ge=0, le=20160, description="minutes before start")
    method: ReminderMethod = ReminderMethod.PUSH


class ReminderOut(ORMModel):
    id: uuid.UUID
    offset_minutes: int
    method: ReminderMethod
    scheduled_at: datetime
    sent_at: datetime | None = None


# ---------------------------------------------------------------- participants
class ParticipantIn(BaseModel):
    user_id: uuid.UUID
    is_required: bool = True


class ParticipantOut(ORMModel):
    id: uuid.UUID
    user_id: uuid.UUID
    user: UserBrief | None = None
    is_organizer: bool
    is_required: bool
    response: ParticipantResponse
    responded_at: datetime | None = None


class ParticipantResponseIn(BaseModel):
    response: ParticipantResponse


# ---------------------------------------------------------------- events
class EventCreate(BaseModel):
    calendar_id: uuid.UUID
    title: str = Field(min_length=1, max_length=250)
    description: str | None = None
    location: str | None = Field(None, max_length=250)
    category_id: uuid.UUID | None = None

    starts_at: datetime
    ends_at: datetime
    all_day: bool = False
    timezone: str = Field("Asia/Seoul", max_length=64)

    rrule: str | None = Field(None, max_length=250, description="RFC 5545 RRULE")
    recurrence_end: datetime | None = None

    color: str | None = Field(None, max_length=20)
    is_private: bool = False
    service_ticket_id: uuid.UUID | None = None

    participant_ids: list[uuid.UUID] = Field(
        default_factory=list, description="organizer is added automatically"
    )
    reminders: list[ReminderIn] | None = Field(
        None, description="omit to use the calendar default"
    )

    @model_validator(mode="after")
    def _end_after_start(self) -> "EventCreate":
        if self.ends_at < self.starts_at:
            raise ValueError("종료 시각은 시작 시각보다 빠를 수 없습니다.")
        return self


class EventUpdate(BaseModel):
    title: str | None = Field(None, max_length=250)
    description: str | None = None
    location: str | None = Field(None, max_length=250)
    category_id: uuid.UUID | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    all_day: bool | None = None
    timezone: str | None = Field(None, max_length=64)
    rrule: str | None = Field(None, max_length=250)
    recurrence_end: datetime | None = None
    status: EventStatus | None = None
    color: str | None = Field(None, max_length=20)
    is_private: bool | None = None
    participant_ids: list[uuid.UUID] | None = Field(
        None, description="when present, replaces the whole participant list"
    )
    reminders: list[ReminderIn] | None = Field(
        None, description="when present, replaces the whole reminder list"
    )


class EventOut(ORMModel):
    id: uuid.UUID
    calendar_id: uuid.UUID
    title: str
    description: str | None = None
    location: str | None = None
    category_id: uuid.UUID | None = None
    starts_at: datetime
    ends_at: datetime
    all_day: bool
    timezone: str
    rrule: str | None = None
    recurrence_end: datetime | None = None
    status: EventStatus
    color: str | None = None
    is_private: bool
    service_ticket_id: uuid.UUID | None = None
    created_by_id: uuid.UUID | None = None
    created_at: datetime
    updated_at: datetime


class EventDetail(EventOut):
    calendar: CalendarOut | None = None
    participants: list[ParticipantOut] = Field(default_factory=list)
    reminders: list[ReminderOut] = Field(default_factory=list)


# ---------------------------------------------------------------- notifications
class NotificationOut(ORMModel):
    id: uuid.UUID
    type: NotificationType
    title: str
    body: str | None = None
    payload: dict | None = None
    entity_type: str | None = None
    entity_id: uuid.UUID | None = None
    is_read: bool
    read_at: datetime | None = None
    created_at: datetime


class NotificationCount(BaseModel):
    unread: int


class BroadcastRequest(BaseModel):
    """Admin push. Empty user_ids means everyone with an APPROVED account."""

    title: str = Field(min_length=1, max_length=250)
    body: str | None = None
    user_ids: list[uuid.UUID] = Field(default_factory=list)
