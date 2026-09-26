"""Accounts, departments, sessions and push-registered devices."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import (
    Base,
    SoftDeleteMixin,
    TimestampMixin,
    UTCDateTime,
    UUIDMixin,
    enum_type,
)
from app.models.enums import DevicePlatform, Role, UserStatus


class Department(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "departments"

    name: Mapped[str] = mapped_column(String(100), nullable=False)
    code: Mapped[str | None] = mapped_column(String(50), unique=True)
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("departments.id", ondelete="SET NULL")
    )
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    parent: Mapped[Department | None] = relationship(
        remote_side="Department.id", back_populates="children"
    )
    children: Mapped[list[Department]] = relationship(back_populates="parent")
    users: Mapped[list[User]] = relationship(back_populates="department")


class User(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "users"

    email: Mapped[str] = mapped_column(
        String(255), unique=True, index=True, nullable=False
    )
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    full_name: Mapped[str] = mapped_column(String(100), nullable=False)
    employee_no: Mapped[str | None] = mapped_column(String(50), unique=True)
    phone: Mapped[str | None] = mapped_column(String(50))
    position: Mapped[str | None] = mapped_column(String(50))  # 직급
    department_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("departments.id", ondelete="SET NULL")
    )

    role: Mapped[Role] = mapped_column(
        enum_type(Role), default=Role.MEMBER, nullable=False, index=True
    )
    status: Mapped[UserStatus] = mapped_column(
        enum_type(UserStatus), default=UserStatus.PENDING, nullable=False, index=True
    )

    # --- approval trail (가입 -> 관리자 승인) ---
    approved_by_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL")
    )
    approved_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    rejection_reason: Mapped[str | None] = mapped_column(Text)
    signup_note: Mapped[str | None] = mapped_column(Text)  # 가입 신청 시 사유/메모

    # --- login hygiene ---
    last_login_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    failed_login_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    locked_until: Mapped[datetime | None] = mapped_column(UTCDateTime)
    must_change_password: Mapped[bool] = mapped_column(
        Boolean, default=False, nullable=False
    )

    department: Mapped[Department | None] = relationship(
        back_populates="users", foreign_keys=[department_id]
    )
    approved_by: Mapped[User | None] = relationship(
        remote_side="User.id", foreign_keys=[approved_by_id]
    )
    devices: Mapped[list[Device]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )

    @property
    def can_login(self) -> bool:
        return self.status == UserStatus.APPROVED and self.deleted_at is None


class RefreshToken(UUIDMixin, TimestampMixin, Base):
    """One row per issued refresh token, so admins can kill sessions."""

    __tablename__ = "refresh_tokens"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    session_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, default=uuid.uuid4, nullable=False, index=True
    )
    token_hash: Mapped[str] = mapped_column(
        String(64), unique=True, index=True, nullable=False
    )
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    user_agent: Mapped[str | None] = mapped_column(String(255))
    ip_address: Mapped[str | None] = mapped_column(String(64))

    user: Mapped[User] = relationship()


class Device(UUIDMixin, TimestampMixin, Base):
    """Push targets. One user can be on Android + Windows + Linux at once."""

    __tablename__ = "devices"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    session_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, nullable=True, index=True
    )
    platform: Mapped[DevicePlatform] = mapped_column(
        enum_type(DevicePlatform), nullable=False
    )
    push_token: Mapped[str] = mapped_column(String(512), nullable=False)
    device_name: Mapped[str | None] = mapped_column(String(120))
    app_version: Mapped[str | None] = mapped_column(String(40))
    last_seen_at: Mapped[datetime | None] = mapped_column(UTCDateTime)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    user: Mapped[User] = relationship(back_populates="devices")
