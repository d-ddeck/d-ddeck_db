"""Declarative base, shared column mixins, and portable column types."""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, JSON, String, Uuid, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.types import TypeDecorator

# JSON on SQLite, JSONB on PostgreSQL - same Python-side API either way.
JSONType = JSON().with_variant(JSONB, "postgresql")


class UTCDateTime(TypeDecorator):
    """Timezone-aware timestamps that behave identically on SQLite and PostgreSQL.

    SQLite has no timezone storage, so a plain DateTime(timezone=True) reads
    back naive there and aware on PostgreSQL - which blows up the moment app
    code compares a stored timestamp with datetime.now(timezone.utc). This
    normalises to UTC on the way in and re-attaches UTC on the way out, so every
    datetime that crosses the ORM boundary is aware, on both databases.
    """

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    def process_result_value(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)


class Base(DeclarativeBase):
    pass


class UUIDMixin:
    """UUID PKs: safe to generate client-side and to merge across sites later."""

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid, primary_key=True, default=uuid.uuid4, index=True
    )


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, server_default=func.now(), nullable=False, index=True
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime,
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class SoftDeleteMixin:
    """Nothing is hard-deleted; every list query filters on deleted_at IS NULL."""

    deleted_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime, nullable=True, index=True
    )

    @property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None


class AuthorMixin:
    """Who touched the row. Deliberately nullable for system-generated rows."""

    created_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    updated_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )


def str_col(length: int = 255, **kw):
    return mapped_column(String(length), **kw)


def enum_type(py_enum, length: int = 32):
    """VARCHAR-backed enum column: portable, and new members need no migration."""
    from sqlalchemy import Enum as SAEnum

    return SAEnum(
        py_enum,
        native_enum=False,
        length=length,
        values_callable=lambda e: [m.value for m in e],
        validate_strings=True,
    )
