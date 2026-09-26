"""Notification fan-out.

In-app rows are the source of truth; push is a best-effort mirror on top. Push is queued in the same transaction and delivered after commit.
Missing Firebase configuration leaves notifications available in-app.
"""

from __future__ import annotations

import json
import logging
import uuid
from collections.abc import Iterable, Sequence
from datetime import timedelta
from typing import Any

from sqlalchemy import or_, select, update
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.security import now_utc
from app.models.calendar import Notification
from app.models.enums import NotificationType, UserStatus
from app.models.user import Device, User

log = logging.getLogger("ddeck.notify")


def notify(
    db: Session,
    *,
    user_ids: Iterable[uuid.UUID],
    type: NotificationType,
    title: str,
    body: str | None = None,
    payload: dict[str, Any] | None = None,
    entity_type: str | None = None,
    entity_id: uuid.UUID | None = None,
    push: bool = True,
) -> list[Notification]:
    """Creates one Notification row per recipient. Does not commit."""
    unique_ids = list(dict.fromkeys(user_ids))
    if not unique_ids:
        return []

    rows = [
        Notification(
            user_id=uid,
            type=type,
            title=title,
            body=body,
            payload=payload,
            entity_type=entity_type,
            entity_id=entity_id,
            push_pending=bool(
                push and settings.FCM_PROJECT_ID and settings.FCM_CREDENTIALS_FILE
            ),
        )
        for uid in unique_ids
    ]
    db.add_all(rows)

    return rows


def notify_all(
    db: Session,
    *,
    type: NotificationType,
    title: str,
    body: str | None = None,
    payload: dict[str, Any] | None = None,
) -> list[Notification]:
    """Broadcast to every approved account."""
    ids = db.scalars(
        select(User.id).where(
            User.status == UserStatus.APPROVED, User.deleted_at.is_(None)
        )
    ).all()
    return notify(db, user_ids=ids, type=type, title=title, body=body, payload=payload)


def dispatch_push(db: Session, limit: int = 100) -> int:
    """Claim committed outbox rows; retry transient errors with bounded backoff.

    Delivery is at-least-once: a process crash after FCM accepts a message may
    resend it. notification_id lets clients deduplicate it.
    """
    if not settings.FCM_PROJECT_ID or not settings.FCM_CREDENTIALS_FILE:
        return 0
    now = now_utc()
    eligible = (
        Notification.push_pending.is_(True),
        or_(Notification.push_after.is_(None), Notification.push_after <= now),
    )
    ids = db.scalars(
        select(Notification.id)
        .where(*eligible)
        .order_by(Notification.created_at)
        .limit(limit)
    ).all()
    sent = 0
    for identifier in ids:
        changed = db.execute(
            update(Notification)
            .where(Notification.id == identifier, *eligible)
            .values(
                push_after=now + timedelta(minutes=10),
                push_attempts=Notification.push_attempts + 1,
            )
        ).rowcount
        db.commit()
        if changed != 1:
            continue
        row = db.get(Notification, identifier)
        devices = db.scalars(
            select(Device).where(
                Device.user_id == row.user_id, Device.is_active.is_(True)
            )
        ).all()
        try:
            invalid = send_push(
                [device.push_token for device in devices],
                row.title,
                row.body,
                {**(row.payload or {}), "notification_id": str(row.id)},
            )
            for device in devices:
                if device.push_token in invalid:
                    device.is_active = False
            row.pushed_at = now_utc() if devices else None
            row.push_pending = False
            sent += 1
        except Exception:  # noqa: BLE001 - isolate background/diagnostic failures
            # Never log credentials, device tokens or message contents.
            log.warning(
                "FCM delivery failed for notification %s (attempt %s)",
                row.id,
                row.push_attempts,
            )
            row.push_pending = row.push_attempts < 8
            row.push_after = now_utc() + timedelta(
                seconds=min(3600, 30 * 2**row.push_attempts)
            )
        db.commit()
    return sent


def send_push(
    tokens: Sequence[str], title: str, body: str | None, payload: dict[str, Any] | None
) -> set[str]:
    """FCM HTTP v1 service-account delivery. Return unregistered device tokens."""
    if not tokens:
        return set()
    import httpx
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account

    credentials = service_account.Credentials.from_service_account_file(
        settings.FCM_CREDENTIALS_FILE,
        scopes=["https://www.googleapis.com/auth/firebase.messaging"],
    )
    credentials.refresh(Request())
    invalid = set()
    with httpx.Client(timeout=20) as client:
        for token in tokens:
            response = client.post(
                f"https://fcm.googleapis.com/v1/projects/{settings.FCM_PROJECT_ID}/messages:send",
                headers={"Authorization": f"Bearer {credentials.token}"},
                json={
                    "message": {
                        "token": token,
                        "notification": {"title": title, "body": body or ""},
                        "data": {
                            key: value
                            if isinstance(value, str)
                            else json.dumps(value, ensure_ascii=False)
                            for key, value in (payload or {}).items()
                        },
                    }
                },
            )
            if response.status_code == 404 and any(
                detail.get("errorCode") == "UNREGISTERED"
                for detail in response.json().get("error", {}).get("details", [])
            ):
                invalid.add(token)
            else:
                response.raise_for_status()
    return invalid
