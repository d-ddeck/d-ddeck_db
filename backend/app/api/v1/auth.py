"""Entry flow: 회원가입 -> (관리자 승인) -> 로그인 -> 서버 이용.

Signup never grants access; it creates a PENDING row and pings the admins.
An account only becomes usable once an admin approves it.
"""
from __future__ import annotations

import uuid
from datetime import timedelta

import jwt
from fastapi import APIRouter, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings as env
from app.core.deps import Client, CurrentUser, DbSession
from app.core.errors import AppError
from app.core.security import (
    create_token,
    hash_password,
    hash_refresh_token,
    now_utc,
    verify_password,
)
from app.models.enums import (
    AuditAction,
    ModuleKey,
    NotificationType,
    Role,
    UserStatus,
)
from app.models.user import Device, RefreshToken, User
from app.schemas.auth import (
    AccessToken,
    ChangePasswordRequest,
    DeviceOut,
    DeviceRegister,
    LoginRequest,
    RefreshRequest,
    SessionOut,
    SignupRequest,
    TokenPair,
    UserProfile,
    UserUpdateSelf,
)
from app.schemas.common import Message
from app.services import audit, notifications, settings_store

router = APIRouter(prefix="/auth", tags=["auth"])


# ------------------------------------------------------------------ signup
@router.post("/signup", response_model=Message, status_code=status.HTTP_201_CREATED)
def signup(payload: SignupRequest, db: DbSession, client: Client) -> Message:
    email = payload.email.lower().strip()

    if db.scalar(select(User.id).where(User.email == email)):
        raise AppError("EMAIL_TAKEN", "이미 등록된 이메일입니다.", status.HTTP_409_CONFLICT)

    allowed = settings_store.get(db, ModuleKey.AUTH, "allowed_email_domains", []) or []
    if allowed and email.rsplit("@", 1)[-1] not in allowed:
        raise AppError(
            "EMAIL_DOMAIN_NOT_ALLOWED",
            f"허용된 이메일 도메인이 아닙니다. ({', '.join(allowed)})",
            status.HTTP_400_BAD_REQUEST,
        )

    if payload.employee_no and db.scalar(
        select(User.id).where(User.employee_no == payload.employee_no)
    ):
        raise AppError("EMPNO_TAKEN", "이미 등록된 사번입니다.", status.HTTP_409_CONFLICT)

    # If approval is switched off in the 관리 설정, the account is usable at once.
    needs_approval = settings_store.get(db, ModuleKey.AUTH, "require_admin_approval", True)

    user = User(
        email=email,
        password_hash=hash_password(payload.password),
        full_name=payload.full_name.strip(),
        employee_no=payload.employee_no,
        phone=payload.phone,
        position=payload.position,
        department_id=payload.department_id,
        signup_note=payload.signup_note,
        role=Role.MEMBER,
        status=UserStatus.PENDING if needs_approval else UserStatus.APPROVED,
        approved_at=None if needs_approval else now_utc(),
    )
    db.add(user)
    db.flush()

    audit.record(
        db,
        action=AuditAction.CREATE,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary=f"회원가입 신청: {email}",
        client=client,
    )

    if needs_approval:
        admin_ids = db.scalars(
            select(User.id).where(
                User.role.in_([Role.ADMIN, Role.SUPERADMIN]),
                User.status == UserStatus.APPROVED,
                User.deleted_at.is_(None),
            )
        ).all()
        notifications.notify(
            db,
            user_ids=admin_ids,
            type=NotificationType.SYSTEM,
            title="가입 승인 요청",
            body=f"{user.full_name}({email}) 님이 가입을 신청했습니다.",
            payload={"route": "/admin/users/pending", "user_id": str(user.id)},
            entity_type="user",
            entity_id=user.id,
        )

    db.commit()
    return Message(
        message=(
            "가입 신청이 접수되었습니다. 관리자 승인 후 로그인할 수 있습니다."
            if needs_approval
            else "가입이 완료되었습니다. 로그인해 주세요."
        )
    )


# ------------------------------------------------------------------ login
@router.post("/login", response_model=TokenPair)
def login(payload: LoginRequest, db: DbSession, client: Client) -> TokenPair:
    email = payload.email.lower().strip()
    user = db.scalar(select(User).where(User.email == email, User.deleted_at.is_(None)))

    # Same error for unknown email and wrong password: do not leak who has an account.
    bad_credentials = AppError(
        "INVALID_CREDENTIALS",
        "이메일 또는 비밀번호가 올바르지 않습니다.",
        status.HTTP_401_UNAUTHORIZED,
    )
    if user is None:
        audit.record(
            db,
            action=AuditAction.LOGIN_FAILED,
            module=ModuleKey.AUTH,
            summary=f"존재하지 않는 계정 로그인 시도: {email}",
            client=client,
        )
        db.commit()
        raise bad_credentials

    now = now_utc()
    if user.locked_until and user.locked_until > now:
        remaining = int((user.locked_until - now).total_seconds() // 60) + 1
        raise AppError(
            "ACCOUNT_LOCKED",
            f"로그인 시도 횟수를 초과했습니다. {remaining}분 후 다시 시도해 주세요.",
            status.HTTP_423_LOCKED,
        )

    if not verify_password(payload.password, user.password_hash):
        max_fail = settings_store.get(db, ModuleKey.AUTH, "max_failed_logins", 5)
        lock_minutes = settings_store.get(db, ModuleKey.AUTH, "lockout_minutes", 15)
        user.failed_login_count += 1
        if user.failed_login_count >= max_fail:
            user.locked_until = now + timedelta(minutes=lock_minutes)
            user.failed_login_count = 0
        audit.record(
            db,
            action=AuditAction.LOGIN_FAILED,
            actor=user,
            module=ModuleKey.AUTH,
            entity_type="user",
            entity_id=user.id,
            summary="비밀번호 불일치",
            client=client,
        )
        db.commit()
        raise bad_credentials

    if not user.can_login:
        raise AppError(
            "ACCOUNT_NOT_ACTIVE",
            {
                UserStatus.PENDING: "관리자 승인 대기 중입니다.",
                UserStatus.REJECTED: f"가입이 반려되었습니다. 사유: {user.rejection_reason or '-'}",
                UserStatus.SUSPENDED: "정지된 계정입니다. 관리자에게 문의하세요.",
                UserStatus.RESIGNED: "퇴사 처리된 계정입니다.",
            }.get(user.status, "사용할 수 없는 계정입니다."),
            status.HTTP_403_FORBIDDEN,
            {"status": user.status.value},
        )

    user.failed_login_count = 0
    user.locked_until = None
    user.last_login_at = now

    pair = _issue_tokens(db, user, client, device_name=payload.device_name)
    audit.record(
        db,
        action=AuditAction.LOGIN,
        actor=user,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary="로그인 성공",
        client=client,
    )
    db.commit()
    return pair


def _issue_tokens(
    db: Session, user: User, client, device_name: str | None = None
) -> TokenPair:
    access, access_exp = create_token(
        user.id, "access", {"role": user.role.value, "email": user.email}
    )
    refresh, refresh_exp = create_token(user.id, "refresh")
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=hash_refresh_token(refresh),
            expires_at=refresh_exp,
            user_agent=(device_name or client.user_agent or "")[:255] or None,
            ip_address=client.ip,
        )
    )
    db.flush()
    return TokenPair(
        access_token=access,
        refresh_token=refresh,
        expires_at=access_exp,
        user=UserProfile.model_validate(user),
    )


# ------------------------------------------------------------------ refresh
@router.post("/refresh", response_model=AccessToken)
def refresh_token(payload: RefreshRequest, db: DbSession) -> AccessToken:
    try:
        claims = jwt.decode(
            payload.refresh_token, env.SECRET_KEY, algorithms=[env.ALGORITHM]
        )
    except jwt.PyJWTError:
        raise AppError(
            "INVALID_TOKEN", "유효하지 않은 토큰입니다.", status.HTTP_401_UNAUTHORIZED
        ) from None
    if claims.get("typ") != "refresh":
        raise AppError(
            "INVALID_TOKEN", "리프레시 토큰이 아닙니다.", status.HTTP_401_UNAUTHORIZED
        )

    # The DB row is what makes revocation possible - a valid signature is not enough.
    row = db.scalar(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(payload.refresh_token)
        )
    )
    if row is None or row.revoked_at is not None or row.expires_at <= now_utc():
        raise AppError(
            "SESSION_EXPIRED",
            "세션이 만료되었습니다. 다시 로그인해 주세요.",
            status.HTTP_401_UNAUTHORIZED,
        )

    user = db.get(User, row.user_id)
    if user is None or not user.can_login:
        raise AppError(
            "ACCOUNT_NOT_ACTIVE", "사용할 수 없는 계정입니다.", status.HTTP_403_FORBIDDEN
        )

    access, access_exp = create_token(
        user.id, "access", {"role": user.role.value, "email": user.email}
    )
    return AccessToken(access_token=access, expires_at=access_exp)


@router.post("/logout", response_model=Message)
def logout(payload: RefreshRequest, db: DbSession, user: CurrentUser, client: Client) -> Message:
    row = db.scalar(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(payload.refresh_token),
            RefreshToken.user_id == user.id,
        )
    )
    if row and row.revoked_at is None:
        row.revoked_at = now_utc()
    audit.record(
        db,
        action=AuditAction.LOGOUT,
        actor=user,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        client=client,
    )
    db.commit()
    return Message(message="로그아웃되었습니다.")


# ------------------------------------------------------------------ profile
@router.get("/me", response_model=UserProfile)
def me(user: CurrentUser) -> UserProfile:
    return UserProfile.model_validate(user)


@router.patch("/me", response_model=UserProfile)
def update_me(payload: UserUpdateSelf, db: DbSession, user: CurrentUser) -> UserProfile:
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(user, field, value)
    db.commit()
    db.refresh(user)
    return UserProfile.model_validate(user)


@router.post("/change-password", response_model=Message)
def change_password(
    payload: ChangePasswordRequest, db: DbSession, user: CurrentUser, client: Client
) -> Message:
    if not verify_password(payload.current_password, user.password_hash):
        raise AppError("WRONG_PASSWORD", "현재 비밀번호가 올바르지 않습니다.")
    if verify_password(payload.new_password, user.password_hash):
        raise AppError("SAME_PASSWORD", "이전과 다른 비밀번호를 사용해 주세요.")

    user.password_hash = hash_password(payload.new_password)
    user.must_change_password = False

    # Every other session dies with the old password.
    for row in db.scalars(
        select(RefreshToken).where(
            RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None)
        )
    ).all():
        row.revoked_at = now_utc()

    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary="비밀번호 변경",
        client=client,
    )
    db.commit()
    return Message(message="비밀번호가 변경되었습니다. 다시 로그인해 주세요.")


# ------------------------------------------------------------------ sessions
@router.get("/sessions", response_model=list[SessionOut])
def my_sessions(db: DbSession, user: CurrentUser) -> list[SessionOut]:
    rows = db.scalars(
        select(RefreshToken)
        .where(RefreshToken.user_id == user.id)
        .order_by(RefreshToken.created_at.desc())
        .limit(50)
    ).all()
    return [SessionOut.model_validate(r) for r in rows]


@router.delete("/sessions/{session_id}", response_model=Message)
def revoke_session(session_id: uuid.UUID, db: DbSession, user: CurrentUser) -> Message:
    row = db.scalar(
        select(RefreshToken).where(
            RefreshToken.id == session_id, RefreshToken.user_id == user.id
        )
    )
    if row is None:
        raise AppError("NOT_FOUND", "세션을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    row.revoked_at = row.revoked_at or now_utc()
    db.commit()
    return Message(message="세션이 해제되었습니다.")


# ------------------------------------------------------------------ devices
@router.post("/devices", response_model=DeviceOut)
def register_device(
    payload: DeviceRegister, db: DbSession, user: CurrentUser
) -> DeviceOut:
    """Upsert by push token so reinstalling the app does not pile up rows."""
    device = db.scalar(
        select(Device).where(
            Device.user_id == user.id, Device.push_token == payload.push_token
        )
    )
    if device is None:
        device = Device(user_id=user.id, push_token=payload.push_token)
        db.add(device)
    device.platform = payload.platform
    device.device_name = payload.device_name
    device.app_version = payload.app_version
    device.last_seen_at = now_utc()
    device.is_active = True
    db.commit()
    db.refresh(device)
    return DeviceOut.model_validate(device)


@router.get("/devices", response_model=list[DeviceOut])
def my_devices(db: DbSession, user: CurrentUser) -> list[DeviceOut]:
    rows = db.scalars(
        select(Device).where(Device.user_id == user.id).order_by(Device.created_at.desc())
    ).all()
    return [DeviceOut.model_validate(r) for r in rows]


@router.delete("/devices/{device_id}", response_model=Message)
def remove_device(device_id: uuid.UUID, db: DbSession, user: CurrentUser) -> Message:
    device = db.scalar(
        select(Device).where(Device.id == device_id, Device.user_id == user.id)
    )
    if device is None:
        raise AppError("NOT_FOUND", "기기를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    db.delete(device)
    db.commit()
    return Message(message="기기 등록이 해제되었습니다.")
