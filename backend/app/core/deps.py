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

from app.core.config import settings
from app.core.database import get_db
from app.core.errors import AppError
from app.core.security import decode_token, now_utc
from app.models.enums import ROLE_LEVEL, Role, UserStatus
from app.models.user import RefreshToken, User

# auto_error=False so we can return our own error envelope instead of Starlette's.
bearer_scheme = HTTPBearer(auto_error=False)

DbSession = Annotated[Session, Depends(get_db)]


def get_current_user(
    request: Request,
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
            "TOKEN_EXPIRED",
            "토큰이 만료되었습니다. 다시 로그인해 주세요.",
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

    try:
        session_id = uuid.UUID(payload["sid"])
    except (KeyError, ValueError, TypeError):
        raise AppError("SESSION_EXPIRED", "다시 로그인해 주세요.", 401) from None
    active = db.scalar(
        select(RefreshToken.id)
        .where(
            RefreshToken.user_id == user.id,
            RefreshToken.session_id == session_id,
            RefreshToken.revoked_at.is_(None),
            RefreshToken.expires_at > now_utc(),
        )
        .limit(1)
    )
    if active is None:
        raise AppError(
            "SESSION_EXPIRED", "세션이 종료되었습니다. 다시 로그인해 주세요.", 401
        )
    request.state.session_id = session_id

    # 초기·초기화된 비밀번호는 서버가 직접 막는다. 클라이언트 화면만 믿으면 curl 로
    # 우회할 수 있다. 비밀번호를 바꾸는 데 필요한 길만 열어 둔다.
    if user.must_change_password and not _password_change_allowed(request):
        raise AppError(
            "PASSWORD_CHANGE_REQUIRED",
            "비밀번호를 먼저 변경해야 합니다.",
            status.HTTP_403_FORBIDDEN,
            {"must_change_password": True},
        )
    from app.models.enums import ModuleKey
    from app.services import settings_store

    if (
        ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.ADMIN]
        and settings_store.get(db, ModuleKey.SYSTEM, "maintenance_mode", False)
        and not _password_change_allowed(request)
    ):
        raise AppError(
            "MAINTENANCE_MODE",
            settings_store.get(db, ModuleKey.SYSTEM, "maintenance_message", "")
            or "서버 점검 중입니다.",
            503,
        )
    return user


_PASSWORD_CHANGE_PATHS = {"/auth/change-password", "/auth/logout"}


def _password_change_allowed(request: Request) -> bool:
    path = request.url.path
    prefix = settings.API_V1_PREFIX
    if prefix and path.startswith(prefix):
        path = path[len(prefix) :]
    if path in _PASSWORD_CHANGE_PATHS:
        return True
    # 프로필 읽기는 허용(앱이 "누구인지" 확인해 변경 화면으로 보낸다), 수정은 아님.
    return path == "/auth/me" and request.method == "GET"


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
    from ipaddress import ip_address, ip_network

    peer = request.client.host if request.client else None
    trusted = [
        ip_network(v.strip(), strict=False)
        for v in settings.TRUSTED_PROXY_IPS.split(",")
        if v.strip()
    ]

    def is_trusted(value):
        try:
            return any(ip_address(value) in network for network in trusted)
        except ValueError:
            return False

    ip = peer
    if peer and is_trusted(peer):
        chain = [
            v.strip()
            for v in request.headers.get("x-forwarded-for", "").split(",")
            if v.strip()
        ]
        for candidate in reversed(chain):
            if not is_trusted(ip):
                break
            try:
                ip_address(candidate)
            except ValueError:
                break
            ip = candidate
    return ClientInfo(ip=ip, user_agent=request.headers.get("user-agent"))


Client = Annotated[ClientInfo, Depends(client_info)]
