"""Notification fan-out.

In-app rows are the source of truth; push is a best-effort mirror on top. The
push sender is a stub so the FCM wiring is a single swap later, and a missing
FCM key degrades to in-app only instead of failing the request.
"""
from __future__ import annotations

import logging
import uuid
from collections.abc import Iterable, Sequence
from typing import Any

from sqlalchemy import select
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
        )
        for uid in unique_ids
    ]
    db.add_all(rows)

    if push:
        db.flush()
        _push(db, rows)
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
        select(User.id).where(User.status == UserStatus.APPROVED, User.deleted_at.is_(None))
    ).all()
    return notify(db, user_ids=ids, type=type, title=title, body=body, payload=payload)


def _push(db: Session, rows: Sequence[Notification]) -> None:
    """Best-effort device push. Never raises into the request path."""
    if not settings.FCM_SERVER_KEY:
        log.debug("FCM key not configured; %d notification(s) stay in-app", len(rows))
        return

    user_ids = {r.user_id for r in rows}
    tokens_by_user: dict[uuid.UUID, list[str]] = {}
    devices = db.scalars(
        select(Device).where(Device.user_id.in_(user_ids), Device.is_active.is_(True))
    ).all()
    for d in devices:
        tokens_by_user.setdefault(d.user_id, []).append(d.push_token)

    sent_at = now_utc()
    for row in rows:
        tokens = tokens_by_user.get(row.user_id)
        if not tokens:
            continue
        try:
            send_push(tokens, row.title, row.body, row.payload)
            row.pushed_at = sent_at
        except Exception:  # noqa: BLE001 - a push failure must not fail the write
            log.exception("push failed for notification %s", row.id)


def send_push(
    tokens: Sequence[str],
    title: str,
    body: str | None,
    payload: dict[str, Any] | None,
) -> None:
    """Delivery adapter.

    Replace the body with an FCM HTTP v1 call (google-auth + httpx) when the
    Firebase project exists. Signature is intentionally transport-agnostic so
    the callers above never change.
    """
    log.info("PUSH -> %d device(s): %s | %s | %s", len(tokens), title, body, payload)
