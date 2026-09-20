"""Shared FastAPI dependencies: current user, role gates, pagination, client info."""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Annotated

import jwt
from fastapi import Depends, Query, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.errors import AppError
from app.core.security import decode_token
from app.models.enums import ROLE_LEVEL, Role, UserStatus
from app.models.user import User

# auto_error=False so we can return our own error envelope instead of Starlette's.
bearer_scheme = HTTPBearer(auto_error=False)

DbSession = Annotated[Session, Depends(get_db)]


def get_current_user(
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> User:
    if credentials is None:
        raise AppError(
            "NOT_AUTHENTICATED", "로그인이 필요합니다.", status.HTTP_401_UNAUTHORIZED
        )
    try:
        payload = decode_token(credentials.credentials, expected_type="access")
    except jwt.ExpiredSignatureError:
        raise AppError(
            "TOKEN_EXPIRED", "토큰이 만료되었습니다. 다시 로그인해 주세요.",
            status.HTTP_401_UNAUTHORIZED,
        ) from None
    except jwt.PyJWTError:
        raise AppError(
            "INVALID_TOKEN", "유효하지 않은 토큰입니다.", status.HTTP_401_UNAUTHORIZED
        ) from None

    try:
        user_id = uuid.UUID(payload["sub"])
    except (KeyError, ValueError):
        raise AppError(
            "INVALID_TOKEN", "유효하지 않은 토큰입니다.", status.HTTP_401_UNAUTHORIZED
        ) from None

    user = db.scalar(select(User).where(User.id == user_id))
    if user is None or user.deleted_at is not None:
        raise AppError(
            "USER_NOT_FOUND", "계정을 찾을 수 없습니다.", status.HTTP_401_UNAUTHORIZED
        )

    # Status is re-checked on every request: an admin suspending an account takes
    # effect immediately, without waiting for the access token to expire.
    if user.status != UserStatus.APPROVED:
        raise AppError(
            "ACCOUNT_NOT_ACTIVE",
            _status_message(user.status),
            status.HTTP_403_FORBIDDEN,
            {"status": user.status.value},
        )
    return user


def _status_message(st: UserStatus) -> str:
    return {
        UserStatus.PENDING: "관리자 승인 대기 중인 계정입니다.",
        UserStatus.REJECTED: "가입이 반려된 계정입니다.",
        UserStatus.SUSPENDED: "정지된 계정입니다. 관리자에게 문의하세요.",
        UserStatus.RESIGNED: "퇴사 처리된 계정입니다.",
    }.get(st, "사용할 수 없는 계정입니다.")


CurrentUser = Annotated[User, Depends(get_current_user)]


def require_role(minimum: Role):
    """Dependency factory. `Depends(require_role(Role.ADMIN))` gates a route."""

    def _checker(user: CurrentUser) -> User:
        if ROLE_LEVEL[user.role] < ROLE_LEVEL[minimum]:
            raise AppError(
                "FORBIDDEN",
                "이 기능에 대한 권한이 없습니다.",
                status.HTTP_403_FORBIDDEN,
                {"required_role": minimum.value, "your_role": user.role.value},
            )
        return user

    return _checker


ManagerUser = Annotated[User, Depends(require_role(Role.MANAGER))]
AdminUser = Annotated[User, Depends(require_role(Role.ADMIN))]
SuperAdminUser = Annotated[User, Depends(require_role(Role.SUPERADMIN))]


@dataclass(slots=True)
class Pagination:
    page: int
    size: int

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.size


def pagination(
    page: Annotated[int, Query(ge=1, description="1-based page number")] = 1,
    size: Annotated[int, Query(ge=1, le=200, description="rows per page")] = 20,
) -> Pagination:
    return Pagination(page=page, size=size)


PageParams = Annotated[Pagination, Depends(pagination)]


@dataclass(slots=True)
class ClientInfo:
    ip: str | None
    user_agent: str | None


def client_info(request: Request) -> ClientInfo:
    # X-Forwarded-For first: behind nginx, request.client.host is the proxy.
    forwarded = request.headers.get("x-forwarded-for")
    ip = forwarded.split(",")[0].strip() if forwarded else (
        request.client.host if request.client else None
    )
    return ClientInfo(ip=ip, user_agent=request.headers.get("user-agent"))


Client = Annotated[ClientInfo, Depends(client_info)]
