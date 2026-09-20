"""Admin plumbing: per-module settings, shared code master, audit trail, attachments.

`ModuleSetting` + `CodeGroup`/`CodeItem` are what the per-module 설정창 edits.
Every module reuses the same two screens instead of growing its own.
"""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
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
    Base,
    JSONType,
    SoftDeleteMixin,
    TimestampMixin,
    UUIDMixin,
    enum_type,
)
from app.models.enums import AuditAction, ModuleKey


class ModuleSetting(UUIDMixin, TimestampMixin, Base):
    """Key/value config per module. The generic backing store for every 설정창."""

    __tablename__ = "module_settings"
    __table_args__ = (UniqueConstraint("module", "key", name="uq_module_setting"),)

    module: Mapped[ModuleKey] = mapped_column(enum_type(ModuleKey), nullable=False, index=True)
    key: Mapped[str] = mapped_column(String(100), nullable=False)
    value: Mapped[Any] = mapped_column(JSONType, nullable=True)
    value_type: Mapped[str] = mapped_column(String(20), default="string", nullable=False)
    label: Mapped[str | None] = mapped_column(String(200))
    description: Mapped[str | None] = mapped_column(Text)
    # is_public: readable by any logged-in user (client needs it to render the UI).
    # Otherwise ADMIN only.
    is_public: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    updated_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )


class CodeGroup(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    """A classification list, e.g. SERVICE_CATEGORY, ASSET_CATEGORY, EVENT_CATEGORY."""

    __tablename__ = "code_groups"

    code: Mapped[str] = mapped_column(String(60), unique=True, index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    module: Mapped[ModuleKey] = mapped_column(enum_type(ModuleKey), nullable=False, index=True)
    description: Mapped[str | None] = mapped_column(Text)
    # System groups are referenced by code in the backend; renaming is fine, deleting is not.
    is_system: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    items: Mapped[list["CodeItem"]] = relationship(
        back_populates="group", cascade="all, delete-orphan", order_by="CodeItem.sort_order"
    )


class CodeItem(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    """One entry in a CodeGroup. Self-referencing for 2-level trees (대분류/소분류)."""

    __tablename__ = "code_items"
    __table_args__ = (UniqueConstraint("group_id", "code", name="uq_code_item"),)

    group_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("code_groups.id", ondelete="CASCADE"), nullable=False, index=True
    )
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("code_items.id", ondelete="SET NULL")
    )
    code: Mapped[str] = mapped_column(String(60), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    color: Mapped[str | None] = mapped_column(String(20))  # #RRGGBB, for chips & charts
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    extra: Mapped[Any] = mapped_column(JSONType, nullable=True)

    group: Mapped["CodeGroup"] = relationship(back_populates="items")
    children: Mapped[list["CodeItem"]] = relationship(remote_side="CodeItem.parent_id")


class AuditLog(UUIDMixin, Base):
    """Append-only. No TimestampMixin: these rows are never updated."""

    __tablename__ = "audit_logs"

    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, index=True
    )
    actor_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    actor_email: Mapped[str | None] = mapped_column(String(255))  # kept if the user is deleted
    action: Mapped[AuditAction] = mapped_column(enum_type(AuditAction), nullable=False, index=True)
    module: Mapped[ModuleKey | None] = mapped_column(enum_type(ModuleKey), index=True)
    entity_type: Mapped[str | None] = mapped_column(String(60), index=True)
    entity_id: Mapped[str | None] = mapped_column(String(64), index=True)
    summary: Mapped[str | None] = mapped_column(Text)
    changes: Mapped[Any] = mapped_column(JSONType, nullable=True)  # {"field": [before, after]}
    ip_address: Mapped[str | None] = mapped_column(String(64))
    user_agent: Mapped[str | None] = mapped_column(String(255))


class Attachment(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    """Polymorphic file store shared by service tickets, posts, assets and events."""

    __tablename__ = "attachments"

    entity_type: Mapped[str] = mapped_column(String(60), nullable=False, index=True)
    entity_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False, index=True)
    original_name: Mapped[str] = mapped_column(String(255), nullable=False)
    stored_path: Mapped[str] = mapped_column(String(500), nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(120))
    size_bytes: Mapped[int] = mapped_column(BigInteger, default=0, nullable=False)
    uploaded_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
