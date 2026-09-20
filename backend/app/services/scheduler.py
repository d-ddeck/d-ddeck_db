"""Background jobs.

The only job in the skeleton is the reminder sweep: it turns due EventReminder
rows into Notification rows (and a push). Runs in-process via APScheduler, which
is right for a single self-hosted server; if the app is ever scaled to multiple
workers this must move to a single leader or an external queue, or every worker
will fire the same reminder.
"""
from __future__ import annotations

import logging

from apscheduler.schedulers.background import BackgroundScheduler
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import SessionLocal
from app.core.security import now_utc
from app.models.calendar import Event, EventParticipant, EventReminder
from app.models.enums import EventStatus, NotificationType
from app.services.notifications import notify

log = logging.getLogger("ddeck.scheduler")

_scheduler: BackgroundScheduler | None = None


def dispatch_due_reminders(db: Session, limit: int = 200) -> int:
    """Send every reminder whose time has come. Returns how many were sent."""
    now = now_utc()
    due = db.scalars(
        select(EventReminder)
        .join(Event, Event.id == EventReminder.event_id)
        .where(
            EventReminder.sent_at.is_(None),
            EventReminder.scheduled_at <= now,
            Event.status == EventStatus.SCHEDULED,
            Event.deleted_at.is_(None),
        )
        .order_by(EventReminder.scheduled_at)
        .limit(limit)
    ).all()

    sent = 0
    for reminder in due:
        event = db.get(Event, reminder.event_id)
        if event is None:
            reminder.sent_at = now  # orphan: retire it rather than retry forever
            continue

        recipients = list(
            db.scalars(
                select(EventParticipant.user_id).where(
                    EventParticipant.event_id == event.id
                )
            ).all()
        )
        if event.created_by_id and event.created_by_id not in recipients:
            recipients.append(event.created_by_id)

        if recipients:
            notify(
                db,
                user_ids=recipients,
                type=NotificationType.EVENT_REMINDER,
                title=f"[일정 알림] {event.title}",
                body=_body(event, reminder.offset_minutes),
                payload={"route": "/calendar/event", "event_id": str(event.id)},
                entity_type="event",
                entity_id=event.id,
            )
        reminder.sent_at = now
        sent += 1

    if sent:
        db.commit()
        log.info("dispatched %d reminder(s)", sent)
    return sent


def _body(event: Event, offset_minutes: int) -> str:
    when = event.starts_at.strftime("%Y-%m-%d %H:%M")
    lead = f"{offset_minutes}분 전" if offset_minutes else "지금"
    place = f" @ {event.location}" if event.location else ""
    return f"{when} 시작 ({lead} 알림){place}"


def _job() -> None:
    db = SessionLocal()
    try:
        dispatch_due_reminders(db)
    except Exception:  # noqa: BLE001 - a job crash must not kill the scheduler
        log.exception("reminder sweep failed")
        db.rollback()
    finally:
        db.close()


def start() -> BackgroundScheduler | None:
    global _scheduler
    if not settings.SCHEDULER_ENABLED or _scheduler is not None:
        return _scheduler
    _scheduler = BackgroundScheduler(timezone="UTC")
    _scheduler.add_job(
        _job,
        "interval",
        seconds=settings.REMINDER_SCAN_SECONDS,
        id="reminder_sweep",
        max_instances=1,
        coalesce=True,  # after a pause, run once instead of catching up N times
    )
    _scheduler.start()
    log.info("scheduler started (every %ds)", settings.REMINDER_SCAN_SECONDS)
    return _scheduler


def shutdown() -> None:
    global _scheduler
    if _scheduler is not None:
        _scheduler.shutdown(wait=False)
        _scheduler = None
