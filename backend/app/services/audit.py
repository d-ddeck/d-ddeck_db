"""Audit-trail helper. Every admin-visible mutation should call record()."""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy.orm import Session

from app.core.deps import ClientInfo
from app.core.security import now_utc
from app.models.admin import AuditLog
from app.models.enums import AuditAction, ModuleKey
from app.models.user import User

# Never copy these into the changes diff, even if a caller passes them in.
_REDACTED = {
    "password",
    "password_hash",
    "new_password",
    "current_password",
    "token",
    "push_token",
    "token_hash",
    "access_token",
    "refresh_token",
}


def diff(before: dict[str, Any], after: dict[str, Any]) -> dict[str, list[Any]]:
    """Field-level before/after, skipping unchanged and secret fields."""
    out: dict[str, list[Any]] = {}
    for key in set(before) | set(after):
        if key in _REDACTED:
            continue
        b, a = before.get(key), after.get(key)
        if b != a:
            out[key] = [_safe(b), _safe(a)]
    return out


def _safe(value: Any) -> Any:
    if isinstance(value, uuid.UUID):
        return str(value)
    if hasattr(value, "isoformat"):
        return value.isoformat()
    if hasattr(value, "value"):  # StrEnum and friends
        return value.value
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def record(
    db: Session,
    *,
    action: AuditAction,
    actor: User | None = None,
    module: ModuleKey | None = None,
    entity_type: str | None = None,
    entity_id: Any = None,
    summary: str | None = None,
    changes: dict[str, Any] | None = None,
    client: ClientInfo | None = None,
) -> AuditLog:
    """Adds the row to the session. The caller's commit persists it, so an audit
    entry can never survive a transaction that rolled back."""
    log = AuditLog(
        created_at=now_utc(),
        actor_id=actor.id if actor else None,
        actor_email=actor.email if actor else None,
        action=action,
        module=module,
        entity_type=entity_type,
        entity_id=str(entity_id) if entity_id is not None else None,
        summary=summary,
        changes=changes or None,
        ip_address=client.ip if client else None,
        user_agent=(client.user_agent[:255] if client and client.user_agent else None),
    )
    db.add(log)
    return log
