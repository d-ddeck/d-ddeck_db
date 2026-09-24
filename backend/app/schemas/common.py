"""Envelope types every module reuses."""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Generic, TypeVar

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints

T = TypeVar("T")

# Deliberately not pydantic's EmailStr.
#
# EmailStr delegates to email-validator, which rejects special-use TLDs such as
# `.local`, `.lan` and `.internal`. Those are exactly the domains an on-premise
# company server runs on, so it would refuse legitimate intranet accounts. This
# checks shape only and normalises case; real deliverability is not our problem
# because accounts are approved by a human admin anyway.
Email = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=3,
        max_length=255,
        pattern=r"^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$",
    ),
    AfterValidator(str.lower),
]

# What the login form accepts: the full address, or just the part before the
# `@`. Staff at a shared office PC type `admin`, not `admin@ddeck.local`, and
# the domain is the same for everyone on an intranet deployment.
#
# Login input only - accounts are still keyed by the full address everywhere
# else, so responses, audit rows and the frontend contract are unchanged.
#
# Hangul is allowed because the accounts carried over from the previous server
# use the employee's name as the id (이재룡@ddeck.local). The character set
# still excludes `%` and `_` so the bare form cannot smuggle a LIKE wildcard
# into the lookup in `auth.login`.
LoginId = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=255,
        pattern=r"^(?:[^@\s]+@[^@\s.]+(\.[^@\s.]+)+|[A-Za-z0-9가-힣.+-]+)$",
    ),
    AfterValidator(str.lower),
]


class ORMModel(BaseModel):
    """Base for response models read straight off SQLAlchemy objects."""

    model_config = ConfigDict(from_attributes=True)


class Page(BaseModel, Generic[T]):
    """Uniform list response. The Flutter client can write one generic parser."""

    items: list[T]
    total: int
    page: int
    size: int
    pages: int

    @classmethod
    def build(cls, items: list[T], total: int, page: int, size: int) -> "Page[T]":
        return cls(
            items=items,
            total=total,
            page=page,
            size=size,
            pages=(total + size - 1) // size if size else 0,
        )


class Message(BaseModel):
    message: str
    ok: bool = True


class IdResponse(BaseModel):
    id: uuid.UUID


class UserBrief(ORMModel):
    """Embedded author/assignee shape. Never exposes email to non-admins."""

    id: uuid.UUID
    full_name: str
    department_id: uuid.UUID | None = None
    position: str | None = None


class CodeItemBrief(ORMModel):
    id: uuid.UUID
    code: str
    name: str
    color: str | None = None


class DateRange(BaseModel):
    date_from: datetime | None = Field(None, description="inclusive, ISO-8601 UTC")
    date_to: datetime | None = Field(None, description="exclusive, ISO-8601 UTC")
