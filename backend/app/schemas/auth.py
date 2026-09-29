"""Signup / approval / login / token payloads."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import ClassVar

from pydantic import BaseModel, Field, field_validator

from app.core.security import validate_password_strength
from app.models.enums import DevicePlatform, Role, UserStatus
from app.schemas.common import Email, LoginId, ORMModel, PatchModel


class SignupRequest(BaseModel):
    """Step 1 of the entry flow. Creates a PENDING account - no login yet."""

    email: Email
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=1, max_length=100)
    employee_no: str | None = Field(None, max_length=50)
    phone: str | None = Field(None, max_length=50)
    position: str | None = Field(None, max_length=50)
    department_id: uuid.UUID | None = None
    signup_note: str | None = Field(None, max_length=1000)

    @field_validator("password")
    @classmethod
    def _strong_enough(cls, v: str) -> str:
        problems = validate_password_strength(v)
        if problems:
            raise ValueError(" ".join(problems))
        return v


class LoginRequest(BaseModel):
    # LoginId, not Email: the field accepts `admin` as well as
    # `admin@ddeck.local`. Accounts are still keyed by the full address - see
    # `_find_login_user` in api/v1/auth.py.
    email: LoginId
    password: str
    # Sent by the client so the token row shows a human-readable session name.
    device_name: str | None = Field(None, max_length=120)
    platform: DevicePlatform | None = None


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_at: datetime
    user: UserProfile


class RefreshRequest(BaseModel):
    refresh_token: str
    push_token: str | None = None


class AccessToken(BaseModel):
    refresh_token: str
    access_token: str
    token_type: str = "bearer"
    expires_at: datetime


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8, max_length=128)

    @field_validator("new_password")
    @classmethod
    def _strong_enough(cls, v: str) -> str:
        problems = validate_password_strength(v)
        if problems:
            raise ValueError(" ".join(problems))
        return v


class DepartmentBrief(ORMModel):
    id: uuid.UUID
    name: str
    code: str | None = None


class UserProfile(ORMModel):
    """What the logged-in user sees about themselves."""

    id: uuid.UUID
    email: Email
    full_name: str
    employee_no: str | None = None
    phone: str | None = None
    position: str | None = None
    role: Role
    status: UserStatus
    department_id: uuid.UUID | None = None
    department: DepartmentBrief | None = None
    must_change_password: bool = False
    last_login_at: datetime | None = None
    created_at: datetime


class UserAdminView(UserProfile):
    """Extra fields only admins may read."""

    approved_at: datetime | None = None
    approved_by_id: uuid.UUID | None = None
    rejection_reason: str | None = None
    signup_note: str | None = None
    failed_login_count: int = 0
    locked_until: datetime | None = None
    updated_at: datetime


class UserUpdateSelf(PatchModel):
    non_nullable: ClassVar[set[str]] = {"full_name"}

    full_name: str | None = Field(None, max_length=100)
    phone: str | None = Field(None, max_length=50)
    position: str | None = Field(None, max_length=50)


class UserUpdateAdmin(PatchModel):
    non_nullable: ClassVar[set[str]] = {"full_name", "status", "role"}

    full_name: str | None = Field(None, max_length=100)
    employee_no: str | None = Field(None, max_length=50)
    phone: str | None = Field(None, max_length=50)
    position: str | None = Field(None, max_length=50)
    department_id: uuid.UUID | None = None
    role: Role | None = None
    status: UserStatus | None = None


class ApproveRequest(BaseModel):
    """Step 2 of the entry flow. Role is set at approval time, not at signup."""

    role: Role = Role.MEMBER
    department_id: uuid.UUID | None = None
    employee_no: str | None = Field(None, max_length=50)


class RejectRequest(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


class DeviceRegister(BaseModel):
    platform: DevicePlatform
    push_token: str = Field(min_length=1, max_length=512)
    device_name: str | None = Field(None, max_length=120)
    app_version: str | None = Field(None, max_length=40)


class DeviceOut(ORMModel):
    id: uuid.UUID
    platform: DevicePlatform
    device_name: str | None = None
    app_version: str | None = None
    last_seen_at: datetime | None = None
    is_active: bool


class SessionOut(ORMModel):
    id: uuid.UUID
    created_at: datetime
    expires_at: datetime
    revoked_at: datetime | None = None
    user_agent: str | None = None
    ip_address: str | None = None


TokenPair.model_rebuild()


class LocalAdminLoginRequest(BaseModel):
    secret: str = Field(min_length=32, max_length=200)
