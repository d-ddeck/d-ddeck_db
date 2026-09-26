"""Materialized recurring events, bounded to a rolling 400-day window."""

from datetime import timedelta, timezone
from uuid import uuid5
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dateutil.rrule import rrulestr
from sqlalchemy import select, update

from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import Attachment
from app.models.calendar import Calendar, Event, EventParticipant, EventReminder


def occurrences(event):
    if not event.rrule:
        return []
    try:
        fields = dict(item.split("=", 1) for item in event.rrule.upper().split(";"))
        if fields.get("FREQ") not in {"DAILY", "WEEKLY", "MONTHLY", "YEARLY"}:
            raise ValueError("frequency")
        if set(fields) - {
            "FREQ",
            "INTERVAL",
            "COUNT",
            "UNTIL",
            "BYDAY",
            "BYMONTHDAY",
            "BYMONTH",
            "WKST",
        }:
            raise ValueError("unsupported rule")
        if int(fields.get("INTERVAL", "1")) < 1 or int(fields.get("COUNT", "1")) < 1:
            raise ValueError("nonpositive rule")
        start = event.starts_at.replace(tzinfo=event.starts_at.tzinfo or timezone.utc)
        rule = rrulestr(event.rrule, dtstart=start.astimezone(ZoneInfo(event.timezone)))
        horizon = max(start, now_utc()) + timedelta(days=400)
        if event.recurrence_end:
            end = event.recurrence_end.replace(
                tzinfo=event.recurrence_end.tzinfo or timezone.utc
            )
            if end < start:
                raise ValueError("end before start")
            horizon = min(horizon, end)
        # Bound iteration too: invalid/very old series cannot consume unlimited CPU.
        result = []
        for count, occurrence in enumerate(rule):
            if count >= 20000:
                raise ValueError("too many occurrences")
            occurrence = occurrence.astimezone(timezone.utc)
            if occurrence > horizon:
                break
            if occurrence > start and occurrence >= now_utc() - timedelta(days=1):
                result.append(occurrence)
                if len(result) > 401:
                    raise ValueError("too many occurrences")
        return result
    except (ValueError, TypeError, OverflowError, ZoneInfoNotFoundError) as exc:
        raise AppError(
            "INVALID_RECURRENCE",
            "반복 규칙과 시간대·종료일을 확인하세요. 일·주·월·년 단위를 지원합니다.",
        ) from exc


def expand(db, event):
    starts = occurrences(event)
    if not starts:
        return 0
    db.flush()
    existing = set(
        db.scalars(select(Event.id).where(Event.recurrence_parent_id == event.id))
    )
    participants = db.scalars(
        select(EventParticipant).where(EventParticipant.event_id == event.id)
    ).all()
    reminders = db.scalars(
        select(EventReminder).where(EventReminder.event_id == event.id)
    ).all()
    fields = (
        "calendar_id",
        "title",
        "description",
        "location",
        "category_id",
        "all_day",
        "timezone",
        "status",
        "color",
        "is_private",
        "service_ticket_id",
        "created_by_id",
    )
    count = 0
    for starts_at in starts:
        identifier = uuid5(event.id, starts_at.isoformat())
        if identifier in existing:
            continue
        child = Event(
            id=identifier,
            recurrence_parent_id=event.id,
            starts_at=starts_at,
            ends_at=starts_at + (event.ends_at - event.starts_at),
            **{key: getattr(event, key) for key in fields},
        )
        db.add(child)
        db.flush()
        for participant in participants:
            db.add(
                EventParticipant(
                    event_id=identifier,
                    user_id=participant.user_id,
                    is_organizer=participant.is_organizer,
                    is_required=participant.is_required,
                    response=participant.response,
                )
            )
        for reminder in reminders:
            db.add(
                EventReminder(
                    event_id=identifier,
                    offset_minutes=reminder.offset_minutes,
                    method=reminder.method,
                    scheduled_at=starts_at - timedelta(minutes=reminder.offset_minutes),
                )
            )
        count += 1
    return count


def retire_child_attachments(db, children):
    if children:
        db.execute(
            update(Attachment)
            .where(
                Attachment.entity_type == "event",
                Attachment.entity_id.in_(children),
                Attachment.deleted_at.is_(None),
            )
            .values(deleted_at=now_utc())
        )


def retire_children(db, event):
    """Keep past history; future occurrences become tombstones."""
    children = list(
        db.scalars(
            select(Event.id).where(
                Event.recurrence_parent_id == event.id,
                Event.starts_at >= now_utc(),
                Event.deleted_at.is_(None),
            )
        )
    )
    retire_child_attachments(db, children)
    db.execute(
        update(Event)
        .where(
            Event.recurrence_parent_id == event.id,
            Event.starts_at >= now_utc(),
            Event.deleted_at.is_(None),
        )
        .values(deleted_at=now_utc())
    )


def rebuild(db, event):
    # Preserve IDs for unchanged dates, but reapply parent fields to future rows.
    from sqlalchemy import delete

    children = list(
        db.scalars(
            select(Event.id).where(
                Event.recurrence_parent_id == event.id, Event.starts_at >= now_utc()
            )
        )
    )
    if children:
        retained = {uuid5(event.id, start.isoformat()) for start in occurrences(event)}
        retire_child_attachments(
            db, [identifier for identifier in children if identifier not in retained]
        )
        db.execute(delete(EventReminder).where(EventReminder.event_id.in_(children)))
        db.execute(
            delete(EventParticipant).where(EventParticipant.event_id.in_(children))
        )
        db.execute(delete(Event).where(Event.id.in_(children)))
    return expand(db, event)


def maintain(db):
    for event in db.scalars(
        select(Event)
        .join(Calendar, Calendar.id == Event.calendar_id)
        .where(
            Calendar.deleted_at.is_(None),
            Event.rrule.is_not(None),
            Event.recurrence_parent_id.is_(None),
            Event.deleted_at.is_(None),
        )
    ).all():
        expand(db, event)
    db.commit()
