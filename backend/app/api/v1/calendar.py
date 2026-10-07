"""캘린더 module: shared schedules, invitations, reminders and notifications."""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Query, status
from pydantic import BaseModel
from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session, selectinload

from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.calendar import (
    Calendar,
    Event,
    EventParticipant,
    EventReminder,
    Notification,
)
from app.models.enums import (
    ROLE_LEVEL,
    AuditAction,
    CalendarType,
    EventStatus,
    ModuleKey,
    NotificationType,
    ParticipantResponse,
    ReminderMethod,
    Role,
)
from app.models.service import ServiceTicket
from app.models.user import User
from app.schemas.calendar import (
    BroadcastRequest,
    CalendarCreate,
    CalendarOut,
    CalendarUpdate,
    EventCreate,
    EventDetail,
    EventOut,
    EventUpdate,
    NotificationCount,
    NotificationOut,
    ParticipantOut,
    ParticipantResponseIn,
    ReminderIn,
    UpcomingReminder,
)
from app.schemas.common import Message, Page, UserBrief
from app.services import audit, notifications, settings_store
from app.services.holidays import korean_holidays
from app.services.scheduler import dispatch_due_reminders

router = APIRouter(prefix="/calendar", tags=["calendar"])


class HolidayOut(BaseModel):
    date: date
    name: str


@router.get("/holidays", response_model=list[HolidayOut])
def holidays(
    db: DbSession,
    _: CurrentUser,
    year: Annotated[int, Query(ge=2000, le=2100)],
) -> list[HolidayOut]:
    """그 해의 한국 공휴일 · 대체공휴일 (구 서버 캘린더와 같은 계산). 추가 휴일은 설정 CALENDAR.extra_holidays."""
    extra = settings_store.get(db, ModuleKey.CALENDAR, "extra_holidays", "") or ""
    return [
        HolidayOut(date=date.fromisoformat(d), name=n)
        for d, n in korean_holidays(year, str(extra)).items()
    ]


# ================================================================== calendars
@router.get("/calendars", response_model=list[CalendarOut])
def list_calendars(db: DbSession, user: CurrentUser) -> list[CalendarOut]:
    rows = db.scalars(
        select(Calendar)
        .where(Calendar.id.in_(_visible_calendar_ids(db, user)))
        .order_by(Calendar.type, Calendar.name)
    ).all()
    return [CalendarOut.model_validate(r) for r in rows]


@router.post(
    "/calendars", response_model=CalendarOut, status_code=status.HTTP_201_CREATED
)
def create_calendar(
    payload: CalendarCreate, db: DbSession, user: CurrentUser
) -> CalendarOut:
    if (
        payload.type != CalendarType.PERSONAL
        and ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]
    ):
        raise AppError(
            "FORBIDDEN",
            "공유 캘린더는 팀장 이상만 만들 수 있습니다.",
            status.HTTP_403_FORBIDDEN,
        )
    if payload.type == CalendarType.PERSONAL and not settings_store.get(
        db, ModuleKey.CALENDAR, "allow_personal_calendar", True
    ):
        raise AppError(
            "PERSONAL_CALENDAR_DISABLED", "개인 캘린더 사용이 비활성화되어 있습니다."
        )

    calendar = Calendar(
        **payload.model_dump(),
        owner_id=user.id if payload.type == CalendarType.PERSONAL else None,
        created_by_id=user.id,
    )
    db.add(calendar)
    db.commit()
    db.refresh(calendar)
    return CalendarOut.model_validate(calendar)


@router.patch("/calendars/{calendar_id}", response_model=CalendarOut)
def update_calendar(
    calendar_id: uuid.UUID, payload: CalendarUpdate, db: DbSession, user: CurrentUser
) -> CalendarOut:
    calendar = _load_calendar(db, calendar_id)
    _require_calendar_admin(calendar, user)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(calendar, field, value)
    calendar.updated_by_id = user.id
    db.commit()
    db.refresh(calendar)
    return CalendarOut.model_validate(calendar)


@router.delete("/calendars/{calendar_id}", response_model=Message)
def delete_calendar(
    calendar_id: uuid.UUID, db: DbSession, user: CurrentUser
) -> Message:
    calendar = _load_calendar(db, calendar_id)
    _require_calendar_admin(calendar, user)
    if calendar.type == CalendarType.COMPANY:
        raise AppError("CANNOT_DELETE", "공유 캘린더는 삭제할 수 없습니다.")
    calendar.deleted_at = now_utc()
    from app.services.attachment_lifecycle import soft_delete

    for event in db.scalars(
        select(Event).where(
            Event.calendar_id == calendar.id, Event.deleted_at.is_(None)
        )
    ):
        event.deleted_at = now_utc()
        soft_delete(db, "event", event.id)
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== events
@router.get("/events", response_model=list[EventOut])
def list_events(
    db: DbSession,
    user: CurrentUser,
    date_from: datetime = Query(description="range start, inclusive"),  # noqa: B008 - FastAPI parameter declaration
    date_to: datetime = Query(description="range end, exclusive"),  # noqa: B008 - FastAPI parameter declaration
    calendar_id: uuid.UUID | None = None,
    mine_only: bool = False,
    category_id: uuid.UUID | None = None,
    participant_id: uuid.UUID | None = None,
) -> list[EventOut]:
    """Month/week view feed.

    Returns every event that OVERLAPS the window, not only those starting in it,
    so a multi-day event still shows on the days it spans.
    """
    if date_to <= date_from:
        raise AppError("BAD_RANGE", "조회 종료일이 시작일보다 빠릅니다.")
    if date_to - date_from > timedelta(days=400):
        raise AppError("RANGE_TOO_WIDE", "한 번에 최대 400일까지 조회할 수 있습니다.")

    visible = _visible_calendar_ids(db, user)
    stmt = (
        select(Event)
        .where(
            Event.deleted_at.is_(None),
            Event.calendar_id.in_([calendar_id] if calendar_id else visible),
            Event.starts_at < date_to,
            Event.ends_at >= date_from,
        )
        .order_by(Event.starts_at)
    )
    if calendar_id and calendar_id not in visible:
        raise AppError(
            "FORBIDDEN", "접근할 수 없는 캘린더입니다.", status.HTTP_403_FORBIDDEN
        )
    if mine_only:
        stmt = stmt.where(
            or_(
                Event.created_by_id == user.id,
                Event.id.in_(
                    select(EventParticipant.event_id).where(
                        EventParticipant.user_id == user.id
                    )
                ),
            )
        )

    if category_id:
        stmt = stmt.where(Event.category_id == category_id)
    if participant_id:
        stmt = stmt.where(
            Event.id.in_(
                select(EventParticipant.event_id).where(
                    EventParticipant.user_id == participant_id
                )
            )
        )
    return _masked_events(db, user, db.scalars(stmt).all())


@router.get("/service-tickets/{ticket_id}/events", response_model=list[EventOut])
def ticket_events(
    ticket_id: uuid.UUID, db: DbSession, user: CurrentUser
) -> list[EventOut]:
    """Schedules registered from one 서비스 대응 건, oldest first.

    Only the series root is returned for a recurring event so the ticket does
    not list every expanded occurrence.
    """
    stmt = (
        select(Event)
        .where(
            Event.deleted_at.is_(None),
            Event.service_ticket_id == ticket_id,
            Event.recurrence_parent_id.is_(None),
            or_(
                Event.calendar_id.in_(_visible_calendar_ids(db, user)),
                Event.created_by_id == user.id,
                Event.id.in_(
                    select(EventParticipant.event_id).where(
                        EventParticipant.user_id == user.id
                    )
                ),
            ),
        )
        .order_by(Event.starts_at)
    )
    return _masked_events(db, user, db.scalars(stmt).all())


def _masked_events(db: Session, user: User, rows: Sequence[Event]) -> list[EventOut]:
    involved_ids = (
        set(
            db.scalars(
                select(EventParticipant.event_id).where(
                    EventParticipant.user_id == user.id,
                    EventParticipant.event_id.in_([e.id for e in rows]),
                )
            ).all()
        )
        if rows
        else set()
    )
    # A private event shows as a busy block to everyone except its people.
    out: list[EventOut] = []
    for e in rows:
        item = EventOut.model_validate(e)
        if e.is_private and not (
            e.id in involved_ids
            or e.created_by_id == user.id
            or ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.MANAGER]
        ):
            item.title = "비공개 일정"
            item.description = None
            item.location = None
        out.append(item)
    return out


@router.post("/events", response_model=EventDetail, status_code=status.HTTP_201_CREATED)
def create_event(
    payload: EventCreate, db: DbSession, user: CurrentUser, client: Client
) -> EventDetail:
    calendar = _load_calendar(db, payload.calendar_id)
    if calendar.id not in _visible_calendar_ids(db, user):
        raise AppError(
            "FORBIDDEN", "접근할 수 없는 캘린더입니다.", status.HTTP_403_FORBIDDEN
        )
    if payload.service_ticket_id is not None and (
        db.scalar(
            select(ServiceTicket.id).where(
                ServiceTicket.id == payload.service_ticket_id,
                ServiceTicket.deleted_at.is_(None),
            )
        )
        is None
    ):
        raise AppError(
            "NOT_FOUND", "연결할 서비스 건을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )

    data = payload.model_dump(exclude={"participant_ids", "reminders"})
    event = Event(**data, created_by_id=user.id)
    db.add(event)
    db.flush()

    # The organiser is always a participant, so reminders reach them too.
    participant_ids = list(dict.fromkeys([user.id, *payload.participant_ids]))
    for uid in participant_ids:
        db.add(
            EventParticipant(
                event_id=event.id,
                user_id=uid,
                is_organizer=(uid == user.id),
                response=(
                    ParticipantResponse.ACCEPTED
                    if uid == user.id
                    else ParticipantResponse.PENDING
                ),
            )
        )

    _set_reminders(db, event, payload.reminders, calendar)
    from app.services.recurrence import expand

    expand(db, event)

    invitees = [uid for uid in participant_ids if uid != user.id]
    if invitees:
        notifications.notify(
            db,
            user_ids=invitees,
            type=NotificationType.EVENT_INVITED,
            title=f"[일정 초대] {event.title}",
            body=_when(event),
            payload={"route": "/calendar/event", "event_id": str(event.id)},
            entity_type="event",
            entity_id=event.id,
        )
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.CALENDAR,
        entity_type="event",
        entity_id=event.id,
        summary=f"일정 등록: {event.title}",
        client=client,
    )
    db.commit()
    return _event_detail(db, event.id)


@router.get("/events/{event_id}", response_model=EventDetail)
def get_event(event_id: uuid.UUID, db: DbSession, user: CurrentUser) -> EventDetail:
    event = _load_event(db, event_id)
    if event.calendar_id not in _visible_calendar_ids(db, user) and not _is_involved(
        db, event, user
    ):
        raise AppError(
            "FORBIDDEN", "접근할 수 없는 일정입니다.", status.HTTP_403_FORBIDDEN
        )
    if event.is_private and not _is_involved(db, event, user):
        raise AppError("FORBIDDEN", "비공개 일정입니다.", status.HTTP_403_FORBIDDEN)
    return _event_detail(db, event_id)


@router.patch("/events/{event_id}", response_model=EventDetail)
def update_event(
    event_id: uuid.UUID,
    payload: EventUpdate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> EventDetail:
    event = _load_event(db, event_id)
    _require_event_owner(db, event, user)
    data = payload.model_dump(
        exclude={"participant_ids", "reminders"}, exclude_unset=True
    )
    before = {k: getattr(event, k) for k in data}

    for field, value in data.items():
        setattr(event, field, value)
    if event.ends_at < event.starts_at:
        raise AppError("BAD_RANGE", "종료 시각은 시작 시각보다 빠를 수 없습니다.")
    event.updated_by_id = user.id

    if payload.participant_ids is not None:
        _replace_participants(db, event, payload.participant_ids, user)

    # Any time change invalidates the precomputed reminder times.
    if payload.reminders is not None or "starts_at" in data:
        calendar = _load_calendar(db, event.calendar_id)
        specs = payload.reminders
        if specs is None:
            # 시각만 바뀐 경우: 기존 알림(시점 · 방법)을 그대로 새 시각에 맞춰 다시 계산한다.
            # 기본값으로 되돌리면 사용자가 정해 둔 알림이 사라진다.
            specs = [
                ReminderIn(offset_minutes=r.offset_minutes, method=r.method)
                for r in db.scalars(
                    select(EventReminder).where(EventReminder.event_id == event.id)
                ).all()
            ]
        _set_reminders(db, event, specs, calendar, replace=True)

    if event.recurrence_parent_id is None:
        from app.services.recurrence import rebuild

        rebuild(db, event)
    elif event.rrule:
        raise AppError(
            "NESTED_RECURRENCE", "반복 일정의 개별 항목에는 반복을 설정할 수 없습니다."
        )

    existing = db.scalars(
        select(EventParticipant.user_id).where(EventParticipant.event_id == event.id)
    ).all()
    recipients = [uid for uid in existing if uid != user.id]
    if recipients and ("starts_at" in data or "ends_at" in data or "location" in data):
        notifications.notify(
            db,
            user_ids=recipients,
            type=NotificationType.EVENT_UPDATED,
            title=f"[일정 변경] {event.title}",
            body=_when(event),
            payload={"route": "/calendar/event", "event_id": str(event.id)},
            entity_type="event",
            entity_id=event.id,
        )
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.CALENDAR,
        entity_type="event",
        entity_id=event.id,
        summary=f"일정 수정: {event.title}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    return _event_detail(db, event_id)


@router.delete("/events/{event_id}", response_model=Message)
def delete_event(
    event_id: uuid.UUID, db: DbSession, user: CurrentUser, client: Client
) -> Message:
    event = _load_event(db, event_id)
    _require_event_owner(db, event, user)
    event.deleted_at = now_utc()
    from app.services.attachment_lifecycle import soft_delete

    soft_delete(db, "event", event.id)
    event.status = EventStatus.CANCELED
    from app.services.recurrence import retire_children

    retire_children(db, event)

    recipients = [
        uid
        for uid in db.scalars(
            select(EventParticipant.user_id).where(
                EventParticipant.event_id == event.id
            )
        ).all()
        if uid != user.id
    ]
    if recipients:
        notifications.notify(
            db,
            user_ids=recipients,
            type=NotificationType.EVENT_CANCELED,
            title=f"[일정 취소] {event.title}",
            body=_when(event),
            entity_type="event",
            entity_id=event.id,
        )
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=user,
        module=ModuleKey.CALENDAR,
        entity_type="event",
        entity_id=event.id,
        summary=f"일정 삭제: {event.title}",
        client=client,
    )
    db.commit()
    return Message(message="일정이 삭제되었습니다.")


@router.post("/events/{event_id}/respond", response_model=ParticipantOut)
def respond(
    event_id: uuid.UUID,
    payload: ParticipantResponseIn,
    db: DbSession,
    user: CurrentUser,
) -> ParticipantOut:
    row = db.scalar(
        select(EventParticipant).where(
            EventParticipant.event_id == event_id, EventParticipant.user_id == user.id
        )
    )
    if row is None:
        raise AppError(
            "NOT_INVITED", "초대된 일정이 아닙니다.", status.HTTP_403_FORBIDDEN
        )
    row.response = payload.response
    row.responded_at = now_utc()
    db.commit()
    db.refresh(row)
    out = ParticipantOut.model_validate(row)
    out.user = UserBrief.model_validate(user)
    return out


# ================================================================== notifications
@router.get("/notifications", response_model=Page[NotificationOut])
def list_notifications(
    db: DbSession, user: CurrentUser, page: PageParams, unread_only: bool = False
) -> Page[NotificationOut]:
    stmt = select(Notification).where(Notification.user_id == user.id)
    if unread_only:
        stmt = stmt.where(Notification.is_read.is_(False))
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(Notification.created_at.desc())
        .offset(page.offset)
        .limit(page.size)
    ).all()
    return Page.build(
        [NotificationOut.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.get("/notifications/count", response_model=NotificationCount)
def unread_count(db: DbSession, user: CurrentUser) -> NotificationCount:
    n = db.scalar(
        select(func.count(Notification.id)).where(
            Notification.user_id == user.id, Notification.is_read.is_(False)
        )
    )
    return NotificationCount(unread=n or 0)


@router.post("/notifications/{notification_id}/read", response_model=Message)
def mark_read(notification_id: uuid.UUID, db: DbSession, user: CurrentUser) -> Message:
    row = db.scalar(
        select(Notification).where(
            Notification.id == notification_id, Notification.user_id == user.id
        )
    )
    if row is None:
        raise AppError(
            "NOT_FOUND", "알림을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    if not row.is_read:
        row.is_read = True
        row.read_at = now_utc()
        db.commit()
    return Message(message="읽음 처리되었습니다.")


@router.post("/notifications/read-all", response_model=Message)
def mark_all_read(db: DbSession, user: CurrentUser) -> Message:
    now = now_utc()
    rows = db.scalars(
        select(Notification).where(
            Notification.user_id == user.id, Notification.is_read.is_(False)
        )
    ).all()
    for row in rows:
        row.is_read = True
        row.read_at = now
    db.commit()
    return Message(message=f"{len(rows)}건을 읽음 처리했습니다.")


@router.delete("/notifications", response_model=Message)
def clear_notifications(db: DbSession, user: CurrentUser) -> Message:
    """알림 화면의 초기화: 내 알림을 모두 지운다 (다른 사람 알림은 그대로)."""
    rows = db.scalars(
        select(Notification).where(Notification.user_id == user.id)
    ).all()
    for row in rows:
        db.delete(row)
    db.commit()
    return Message(message=f"알림 {len(rows)}건을 지웠습니다.")


@router.post("/notifications/broadcast", response_model=Message)
def broadcast(payload: BroadcastRequest, db: DbSession, admin: AdminUser) -> Message:
    if payload.user_ids:
        rows = notifications.notify(
            db,
            user_ids=payload.user_ids,
            type=NotificationType.SYSTEM,
            title=payload.title,
            body=payload.body,
        )
    else:
        rows = notifications.notify_all(
            db, type=NotificationType.SYSTEM, title=payload.title, body=payload.body
        )
    db.commit()
    return Message(message=f"{len(rows)}명에게 발송했습니다.")


@router.get("/reminders/upcoming", response_model=list[UpcomingReminder])
def upcoming_reminders(
    db: DbSession,
    user: CurrentUser,
    days: Annotated[int, Query(ge=1, le=60, description="look-ahead window")] = 7,
) -> list[UpcomingReminder]:
    """Alarms this user's device should schedule locally.

    The client hands these to the OS alarm scheduler, so a reminder fires even
    with no network and no VPN - the situation someone on the road is actually
    in. Server-side push stays as the mechanism for *changes*; this is the
    mechanism for *ringing*.

    Only reminders the user is a participant of (or organiser of) are returned,
    and only ones that have not already been sent.
    """
    now = now_utc()
    horizon = now + timedelta(days=days)

    rows = db.execute(
        select(EventReminder, Event, Calendar)
        .join(Event, Event.id == EventReminder.event_id)
        .join(Calendar, Calendar.id == Event.calendar_id)
        .outerjoin(
            EventParticipant,
            and_(
                EventParticipant.event_id == Event.id,
                EventParticipant.user_id == user.id,
            ),
        )
        .where(
            EventReminder.sent_at.is_(None),
            EventReminder.scheduled_at >= now,
            EventReminder.scheduled_at < horizon,
            Event.status == EventStatus.SCHEDULED,
            Event.deleted_at.is_(None),
            Calendar.deleted_at.is_(None),
            # The organiser may not be in the participant table on older rows,
            # so accept either link rather than silently dropping their alarms.
            or_(
                EventParticipant.id.isnot(None),
                Event.created_by_id == user.id,
            ),
        )
        .order_by(EventReminder.scheduled_at)
    ).all()

    return [
        UpcomingReminder(
            reminder_id=reminder.id,
            event_id=event.id,
            title=event.title,
            location=event.location,
            starts_at=event.starts_at,
            ends_at=event.ends_at,
            all_day=event.all_day,
            scheduled_at=reminder.scheduled_at,
            offset_minutes=reminder.offset_minutes,
            color=event.color or calendar.color,
            calendar_name=calendar.name,
        )
        for reminder, event, calendar in rows
    ]


@router.post("/reminders/run", response_model=Message)
def run_reminders(db: DbSession, _: AdminUser) -> Message:
    """Manual trigger for the reminder sweep - useful when testing without
    waiting for the scheduler tick."""
    sent = dispatch_due_reminders(db)
    return Message(message=f"{sent}건의 알림을 발송했습니다.")


# ================================================================== helpers
def _require_calendar_admin(calendar: Calendar, user: User) -> None:
    """A personal calendar belongs to its owner; shared ones to 팀장 이상.

    Deliberately no admin override on personal calendars: an admin has no reason
    to rename someone's private schedule, and the account-level controls
    (suspend, deactivate) already cover the cases where they need to intervene.
    """
    if calendar.type == CalendarType.PERSONAL:
        if calendar.owner_id == user.id:
            return
        raise AppError(
            "FORBIDDEN", "본인 캘린더만 수정할 수 있습니다.", status.HTTP_403_FORBIDDEN
        )
    if ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]:
        raise AppError(
            "FORBIDDEN",
            "공유 캘린더는 팀장 이상만 수정할 수 있습니다.",
            status.HTTP_403_FORBIDDEN,
        )


def _load_calendar(db: Session, calendar_id: uuid.UUID) -> Calendar:
    calendar = db.scalar(
        select(Calendar).where(
            Calendar.id == calendar_id, Calendar.deleted_at.is_(None)
        )
    )
    if calendar is None:
        raise AppError(
            "NOT_FOUND", "캘린더를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return calendar


def _load_event(db: Session, event_id: uuid.UUID) -> Event:
    event = db.scalar(
        select(Event).where(Event.id == event_id, Event.deleted_at.is_(None))
    )
    if event is None:
        raise AppError(
            "NOT_FOUND", "일정을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return event


def _visible_calendar_ids(db: Session, user: User) -> list[uuid.UUID]:
    """COMPANY: everyone. DEPARTMENT: same department. PERSONAL: owner only."""
    conditions = [
        Calendar.type == CalendarType.COMPANY,
        Calendar.owner_id == user.id,
        Calendar.is_shared.is_(True),
    ]
    if user.department_id:
        conditions.append(
            and_(
                Calendar.type == CalendarType.DEPARTMENT,
                Calendar.department_id == user.department_id,
            )
        )
    return list(
        db.scalars(
            select(Calendar.id).where(
                Calendar.deleted_at.is_(None),
                Calendar.is_active.is_(True),
                or_(*conditions),
            )
        ).all()
    )


def _is_involved(db: Session, event: Event, user: User) -> bool:
    if event.created_by_id == user.id:
        return True
    return (
        db.scalar(
            select(EventParticipant.id).where(
                EventParticipant.event_id == event.id,
                EventParticipant.user_id == user.id,
            )
        )
        is not None
    )


def _require_event_owner(db: Session, event: Event, user: User) -> None:
    if event.created_by_id == user.id:
        return
    if ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.MANAGER]:
        return
    organizer = db.scalar(
        select(EventParticipant.id).where(
            EventParticipant.event_id == event.id,
            EventParticipant.user_id == user.id,
            EventParticipant.is_organizer.is_(True),
        )
    )
    if organizer is None:
        raise AppError(
            "FORBIDDEN", "일정 주최자만 수정할 수 있습니다.", status.HTTP_403_FORBIDDEN
        )


def _set_reminders(
    db: Session,
    event: Event,
    reminders: list[ReminderIn] | None,
    calendar: Calendar,
    replace: bool = False,
) -> None:
    """Writes reminder rows with scheduled_at already resolved.

    Falls back to the calendar default when the client sends nothing, which is
    what makes 'register a schedule and the attendees get notified' work without
    the UI having to ask about reminders at all.
    """
    if replace:
        for old in db.scalars(
            select(EventReminder).where(EventReminder.event_id == event.id)
        ).all():
            db.delete(old)

    if reminders is None:
        default = calendar.default_reminder_minutes
        if default is None:
            default = settings_store.get(
                db, ModuleKey.CALENDAR, "default_reminder_minutes", 30
            )
        reminders = (
            [ReminderIn(offset_minutes=int(default), method=ReminderMethod.PUSH)]
            if default is not None
            else []
        )

    for r in reminders:
        db.add(
            EventReminder(
                event_id=event.id,
                offset_minutes=r.offset_minutes,
                method=r.method,
                scheduled_at=event.starts_at - timedelta(minutes=r.offset_minutes),
            )
        )


def _replace_participants(
    db: Session, event: Event, user_ids: list[uuid.UUID], actor: User
) -> None:
    wanted = set(dict.fromkeys([*user_ids, event.created_by_id or actor.id]))
    current = {
        p.user_id: p
        for p in db.scalars(
            select(EventParticipant).where(EventParticipant.event_id == event.id)
        ).all()
    }

    for uid, row in current.items():
        if uid not in wanted:
            db.delete(row)

    added = [uid for uid in wanted if uid not in current]
    for uid in added:
        db.add(
            EventParticipant(
                event_id=event.id,
                user_id=uid,
                is_organizer=(uid == event.created_by_id),
                response=ParticipantResponse.PENDING,
            )
        )
    if added:
        notifications.notify(
            db,
            user_ids=[uid for uid in added if uid != actor.id],
            type=NotificationType.EVENT_INVITED,
            title=f"[일정 초대] {event.title}",
            body=_when(event),
            payload={"route": "/calendar/event", "event_id": str(event.id)},
            entity_type="event",
            entity_id=event.id,
        )


def _when(event: Event) -> str:
    return event.starts_at.strftime("%Y-%m-%d %H:%M") + (
        f" @ {event.location}" if event.location else ""
    )


def _event_detail(db: Session, event_id: uuid.UUID) -> EventDetail:
    event = db.scalar(
        select(Event)
        .where(Event.id == event_id)
        .options(
            selectinload(Event.participants),
            selectinload(Event.reminders),
            selectinload(Event.calendar),
        )
    )
    if event is None:
        raise AppError(
            "NOT_FOUND", "일정을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )

    out = EventDetail.model_validate(event)
    users = (
        {
            u.id: u
            for u in db.scalars(
                select(User).where(User.id.in_([p.user_id for p in event.participants]))
            ).all()
        }
        if event.participants
        else {}
    )
    for p_out, p in zip(out.participants, event.participants, strict=False):
        u = users.get(p.user_id)
        p_out.user = UserBrief.model_validate(u) if u else None
    return out
