"""Bounded retention sweeps. Live files and unread notifications are preserved."""

import logging
from datetime import timedelta

from sqlalchemy import delete, select

from app.core.config import settings
from app.core.security import now_utc
from app.models.admin import Attachment, AuditLog
from app.models.calendar import Notification
from app.models.user import RefreshToken

log = logging.getLogger("ddeck.retention")


def sweep(db, limit=500):
    now = now_utc()
    counts = {}
    rules = [
        (
            RefreshToken,
            RefreshToken.expires_at
            < now - timedelta(days=settings.RETENTION_TOKEN_DAYS),
        ),
        (
            Notification,
            Notification.created_at
            < now - timedelta(days=settings.RETENTION_NOTIFICATION_DAYS),
        ),
        (
            AuditLog,
            AuditLog.created_at < now - timedelta(days=settings.RETENTION_AUDIT_DAYS),
        ),
    ]
    for model, cutoff in rules:
        statement = select(model.id).where(cutoff)
        if model is Notification:
            statement = statement.where(
                Notification.is_read.is_(True), Notification.push_pending.is_(False)
            )
        ids = list(db.scalars(statement.limit(limit)))
        counts[model.__tablename__] = (
            db.execute(delete(model).where(model.id.in_(ids))).rowcount if ids else 0
        )
    counts["attachments"] = 0
    for attachment in db.scalars(
        select(Attachment)
        .where(
            Attachment.deleted_at.is_not(None),
            Attachment.deleted_at
            < now - timedelta(days=settings.RETENTION_ATTACHMENT_DAYS),
        )
        .limit(limit)
    ).all():
        path = (settings.storage_path / attachment.stored_path).resolve()
        if not path.is_relative_to(settings.storage_path.resolve()):
            log.warning("Refused attachment purge outside storage: %s", attachment.id)
            continue
        try:
            path.unlink(missing_ok=True)
        except OSError:
            log.warning("Attachment purge failed: %s", attachment.id)
            continue
        db.delete(attachment)
        counts["attachments"] += 1
    db.commit()
    return counts
