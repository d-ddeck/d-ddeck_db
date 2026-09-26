"""User administration: the approval queue, roles, and the member directory."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import func, or_, select

from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import hash_password, now_utc
from app.models.enums import (
    ROLE_LEVEL,
    AuditAction,
    ModuleKey,
    NotificationType,
    Role,
    UserStatus,
)
from app.models.user import Device, RefreshToken, User
from app.schemas.auth import (
    ApproveRequest,
    RejectRequest,
    SessionOut,
    UserAdminView,
    UserUpdateAdmin,
)
from app.schemas.common import Message, Page, UserBrief
from app.services import audit, notifications

router = APIRouter(prefix="/users", tags=["users"])


# ------------------------------------------------------------------ directory
@router.get("/directory", response_model=Page[UserBrief])
def directory(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    q: Annotated[str | None, Query(description="name / employee no")] = None,
    department_id: uuid.UUID | None = None,
) -> Page[UserBrief]:
    """Approved members only. Any logged-in user may read this - it is what the
    assignee and participant pickers are built on."""
    stmt = select(User).where(
        User.status == UserStatus.APPROVED, User.deleted_at.is_(None)
    )
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(or_(User.full_name.ilike(like), User.employee_no.ilike(like)))
    if department_id:
        stmt = stmt.where(User.department_id == department_id)

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(User.full_name).offset(page.offset).limit(page.size)
    ).all()
    return Page.build(
        [UserBrief.model_validate(r) for r in rows], total, page.page, page.size
    )


# ------------------------------------------------------------------ admin list
@router.get("", response_model=Page[UserAdminView])
def list_users(
    db: DbSession,
    _: AdminUser,
    page: PageParams,
    user_status: Annotated[UserStatus | None, Query(alias="status")] = None,
    role: Role | None = None,
    department_id: uuid.UUID | None = None,
    q: str | None = None,
) -> Page[UserAdminView]:
    stmt = select(User).where(User.deleted_at.is_(None))
    if user_status:
        stmt = stmt.where(User.status == user_status)
    if role:
        stmt = stmt.where(User.role == role)
    if department_id:
        stmt = stmt.where(User.department_id == department_id)
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                User.full_name.ilike(like),
                User.email.ilike(like),
                User.employee_no.ilike(like),
            )
        )

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(User.created_at.desc()).offset(page.offset).limit(page.size)
    ).all()
    return Page.build(
        [UserAdminView.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.get("/pending", response_model=Page[UserAdminView])
def pending_queue(db: DbSession, _: AdminUser, page: PageParams) -> Page[UserAdminView]:
    """The 관리기능 approval inbox: oldest request first."""
    stmt = select(User).where(
        User.status == UserStatus.PENDING, User.deleted_at.is_(None)
    )
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(User.created_at).offset(page.offset).limit(page.size)
    ).all()
    return Page.build(
        [UserAdminView.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.get("/{user_id}", response_model=UserAdminView)
def get_user(user_id: uuid.UUID, db: DbSession, _: AdminUser) -> UserAdminView:
    user = _load(db, user_id)
    return UserAdminView.model_validate(user)


# ------------------------------------------------------------------ approval
@router.post("/{user_id}/approve", response_model=UserAdminView)
def approve(
    user_id: uuid.UUID,
    payload: ApproveRequest,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> UserAdminView:
    user = _load(db, user_id)
    _guard_target(admin, user)
    if user.status == UserStatus.APPROVED:
        raise AppError("ALREADY_APPROVED", "이미 승인된 계정입니다.")
    _guard_role_grant(admin, payload.role)

    user.status = UserStatus.APPROVED
    user.role = payload.role
    user.approved_by_id = admin.id
    user.approved_at = now_utc()
    user.rejection_reason = None
    if payload.department_id is not None:
        user.department_id = payload.department_id
    if payload.employee_no is not None:
        user.employee_no = payload.employee_no

    notifications.notify(
        db,
        user_ids=[user.id],
        type=NotificationType.ACCOUNT_APPROVED,
        title="가입이 승인되었습니다",
        body="이제 로그인하여 서버를 이용할 수 있습니다.",
        payload={"route": "/login"},
        entity_type="user",
        entity_id=user.id,
    )
    audit.record(
        db,
        action=AuditAction.APPROVE,
        actor=admin,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary=f"가입 승인: {user.email} (권한 {payload.role.value})",
        client=client,
    )
    db.commit()
    db.refresh(user)
    return UserAdminView.model_validate(user)


@router.post("/{user_id}/reject", response_model=UserAdminView)
def reject(
    user_id: uuid.UUID,
    payload: RejectRequest,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> UserAdminView:
    user = _load(db, user_id)
    _guard_target(admin, user)
    if user.status != UserStatus.PENDING:
        # 반려는 승인 대기열의 동작이다. 승인된 계정을 막으려면 정지(PATCH status)를 쓴다.
        raise AppError("NOT_PENDING", "승인 대기 중인 계정만 반려할 수 있습니다.")
    user.status = UserStatus.REJECTED
    user.rejection_reason = payload.reason
    user.approved_by_id = admin.id
    user.approved_at = now_utc()

    notifications.notify(
        db,
        user_ids=[user.id],
        type=NotificationType.ACCOUNT_REJECTED,
        title="가입이 반려되었습니다",
        body=payload.reason,
        entity_type="user",
        entity_id=user.id,
        push=False,
    )
    audit.record(
        db,
        action=AuditAction.REJECT,
        actor=admin,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary=f"가입 반려: {user.email} - {payload.reason}",
        client=client,
    )
    db.commit()
    db.refresh(user)
    return UserAdminView.model_validate(user)


# ------------------------------------------------------------------ maintenance
@router.patch("/{user_id}", response_model=UserAdminView)
def update_user(
    user_id: uuid.UUID,
    payload: UserUpdateAdmin,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> UserAdminView:
    user = _load(db, user_id)
    _guard_target(admin, user)
    data = payload.model_dump(exclude_unset=True)

    if "role" in data and data["role"] is not None:
        _guard_role_grant(admin, data["role"])
        if user.id == admin.id and ROLE_LEVEL[data["role"]] < ROLE_LEVEL[admin.role]:
            raise AppError("CANNOT_DEMOTE_SELF", "본인의 권한은 낮출 수 없습니다.")

    if (
        user.status == UserStatus.APPROVED
        and ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.ADMIN]
        and (
            data.get("status", user.status) != UserStatus.APPROVED
            or ROLE_LEVEL[data.get("role", user.role)] < ROLE_LEVEL[Role.ADMIN]
        )
    ):
        remaining = (
            db.scalar(
                select(func.count(User.id)).where(
                    User.id != user.id,
                    User.deleted_at.is_(None),
                    User.status == UserStatus.APPROVED,
                    User.role.in_([Role.ADMIN, Role.SUPERADMIN]),
                )
            )
            or 0
        )
        if remaining == 0:
            raise AppError(
                "LAST_ADMIN", "마지막 관리자는 정지하거나 강등할 수 없습니다."
            )
    before = {k: getattr(user, k) for k in data}
    for field, value in data.items():
        setattr(user, field, value)

    # Losing APPROVED status must also kill live sessions, or the old access
    # token keeps working until it expires.
    if data.get("status") and data["status"] != UserStatus.APPROVED:
        _revoke_all_sessions(db, user.id)

    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary=f"계정 수정: {user.email}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    db.refresh(user)
    return UserAdminView.model_validate(user)


@router.post("/{user_id}/reset-password", response_model=Message)
def reset_password(
    user_id: uuid.UUID, db: DbSession, admin: AdminUser, client: Client
) -> Message:
    """Issues a temporary password and forces a change at next login."""
    import secrets

    user = _load(db, user_id)
    _guard_target(admin, user)
    temp = secrets.token_urlsafe(9)
    user.password_hash = hash_password(temp)
    user.must_change_password = True
    user.failed_login_count = 0
    user.locked_until = None
    _revoke_all_sessions(db, user.id)

    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary=f"비밀번호 초기화: {user.email}",
        client=client,
    )
    db.commit()
    # Returned once, in the response only - never stored in plain text anywhere.
    return Message(message=f"임시 비밀번호: {temp}")


@router.delete("/{user_id}", response_model=Message)
def deactivate(
    user_id: uuid.UUID, db: DbSession, admin: AdminUser, client: Client
) -> Message:
    """Soft delete. History rows keep pointing at the account."""
    user = _load(db, user_id)
    if user.id == admin.id:
        raise AppError("CANNOT_DELETE_SELF", "본인 계정은 삭제할 수 없습니다.")
    _guard_target(admin, user)
    # 구 서버 규칙: 마지막 관리자 계정은 지울 수 없다. 관리자가 한 명도 안 남으면
    # 승인·설정을 아무도 못 하게 된다.
    if ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.ADMIN]:
        remaining = (
            db.scalar(
                select(func.count(User.id)).where(
                    User.id != user.id,
                    User.deleted_at.is_(None),
                    User.status == UserStatus.APPROVED,
                    User.role.in_([Role.ADMIN, Role.SUPERADMIN]),
                )
            )
            or 0
        )
        if remaining == 0:
            raise AppError(
                "LAST_ADMIN",
                "마지막 관리자 계정은 삭제할 수 없습니다. 다른 계정을 먼저 관리자로 만드세요.",
            )

    user.deleted_at = now_utc()
    user.status = UserStatus.RESIGNED
    _revoke_all_sessions(db, user.id)
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=admin,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary=f"계정 비활성화: {user.email}",
        client=client,
    )
    db.commit()
    return Message(message="계정이 비활성화되었습니다.")


# ------------------------------------------------------------------ helpers
def _load(db, user_id: uuid.UUID) -> User:
    user = db.scalar(select(User).where(User.id == user_id, User.deleted_at.is_(None)))
    if user is None:
        raise AppError(
            "NOT_FOUND", "계정을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return user


def _guard_target(admin: User, target: User) -> None:
    """관리자는 자기보다 낮은 권한의 계정만 다룰 수 있다 (SUPERADMIN 은 예외).

    이 가드가 없으면 ADMIN 이 SUPERADMIN 의 비밀번호를 초기화해 그 계정으로 들어가거나,
    강등·정지시켜 최고관리자를 잠글 수 있다. 본인 계정은 통과시키고(자기 강등·삭제는
    각 엔드포인트가 따로 막는다) 승인·반려·수정·초기화·삭제 모두 같은 규칙을 쓴다.
    """
    if target.id == admin.id or admin.role == Role.SUPERADMIN:
        return
    if ROLE_LEVEL[target.role] >= ROLE_LEVEL[admin.role]:
        raise AppError(
            "FORBIDDEN",
            "같거나 높은 권한의 계정은 변경할 수 없습니다.",
            status.HTTP_403_FORBIDDEN,
            {"target_role": target.role.value, "your_role": admin.role.value},
        )


def _guard_role_grant(admin: User, target_role: Role) -> None:
    """Nobody may hand out a role at or above their own level."""
    if (
        ROLE_LEVEL[target_role] >= ROLE_LEVEL[admin.role]
        and admin.role != Role.SUPERADMIN
    ):
        raise AppError(
            "FORBIDDEN",
            "자신과 같거나 높은 권한은 부여할 수 없습니다.",
            status.HTTP_403_FORBIDDEN,
        )


def _revoke_all_sessions(db, user_id: uuid.UUID) -> None:
    for device in db.scalars(select(Device).where(Device.user_id == user_id)).all():
        device.is_active = False
    now = now_utc()
    for row in db.scalars(
        select(RefreshToken).where(
            RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None)
        )
    ).all():
        row.revoked_at = now


@router.get("/{user_id}/sessions", response_model=list[SessionOut])
def user_sessions(user_id: uuid.UUID, db: DbSession, admin: AdminUser):
    target = db.get(User, user_id)
    if target is None or target.deleted_at is not None:
        raise AppError("NOT_FOUND", "계정을 찾을 수 없습니다.", 404)
    _guard_target(admin, target)
    rows = db.scalars(
        select(RefreshToken)
        .where(
            RefreshToken.user_id == user_id,
            RefreshToken.revoked_at.is_(None),
            RefreshToken.expires_at > now_utc(),
        )
        .order_by(RefreshToken.created_at.desc())
    ).all()
    return [SessionOut.model_validate(row) for row in rows]
