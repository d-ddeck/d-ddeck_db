"""관리기능 module.

Two things live here that the other four modules all depend on:

  * /settings/{module} - the generic backing store for every 설정창
  * /codes            - the classification master those screens edit

Plus the operator tooling: departments, audit log, health and system stats.
"""
from __future__ import annotations

import time
import uuid
from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import func, inspect, select, text
from sqlalchemy.orm import Session, selectinload

from app.core.config import settings as env
from app.core.database import engine
from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import AuditLog, CodeGroup, CodeItem, ModuleSetting
from app.models.board import Post
from app.models.calendar import Event, Notification
from app.models.enums import (
    OPEN_SERVICE_STATUSES,
    AuditAction,
    ModuleKey,
    UserStatus,
)
from app.models.inventory import Asset
from app.models.service import ServiceTicket
from app.models.user import Department, User
from app.schemas.admin import (
    AuditLogOut,
    CodeGroupCreate,
    CodeGroupOut,
    CodeGroupUpdate,
    CodeItemCreate,
    CodeItemOut,
    CodeItemReorder,
    CodeItemUpdate,
    DepartmentCreate,
    DepartmentOut,
    DepartmentUpdate,
    HealthOut,
    ModuleSettingsOut,
    SettingBulkUpsert,
    SettingOut,
    SystemStats,
    TableStat,
)
from app.schemas.common import Message
from app.services import audit

router = APIRouter(prefix="/admin", tags=["admin"])

STARTED_AT = time.monotonic()


# ================================================================== settings
@router.get("/settings/{module}", response_model=ModuleSettingsOut)
def get_module_settings(
    module: ModuleKey, db: DbSession, user: CurrentUser
) -> ModuleSettingsOut:
    """Everything one 설정창 renders, in a single request.

    Non-admins get the is_public subset: the client still needs those values to
    draw the UI (labels, page sizes, whether secret posts exist at all).
    """
    is_admin = user.role.value in {"ADMIN", "SUPERADMIN"}
    stmt = select(ModuleSetting).where(ModuleSetting.module == module)
    if not is_admin:
        stmt = stmt.where(ModuleSetting.is_public.is_(True))

    rows = db.scalars(stmt.order_by(ModuleSetting.key)).all()
    groups = db.scalars(
        select(CodeGroup)
        .where(CodeGroup.module == module, CodeGroup.deleted_at.is_(None))
        .options(selectinload(CodeGroup.items))
        .order_by(CodeGroup.code)
    ).all()

    return ModuleSettingsOut(
        module=module,
        settings=[SettingOut.model_validate(r) for r in rows],
        code_groups=[_group_out(g) for g in groups],
    )


@router.put("/settings/{module}", response_model=ModuleSettingsOut)
def save_module_settings(
    module: ModuleKey,
    payload: SettingBulkUpsert,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> ModuleSettingsOut:
    """What a 설정창 Save posts: the whole form at once, upserted by key."""
    changes: dict[str, list] = {}
    for item in payload.settings:
        row = db.scalar(
            select(ModuleSetting).where(
                ModuleSetting.module == module, ModuleSetting.key == item.key
            )
        )
        if row is None:
            row = ModuleSetting(module=module, key=item.key)
            db.add(row)
            changes[item.key] = [None, item.value]
        elif row.value != item.value:
            changes[item.key] = [row.value, item.value]
        row.value = item.value
        row.value_type = item.value_type
        row.label = item.label or row.label
        row.description = item.description or row.description
        row.is_public = item.is_public
        row.updated_by_id = admin.id

    if changes:
        audit.record(
            db,
            action=AuditAction.SETTING_CHANGE,
            actor=admin,
            module=module,
            entity_type="module_setting",
            summary=f"{module.value} 설정 변경 ({len(changes)}건)",
            changes=changes,
            client=client,
        )
    db.commit()
    return get_module_settings(module, db, admin)


# ================================================================== code master
@router.get("/codes", response_model=list[CodeGroupOut])
def list_code_groups(
    db: DbSession, _: CurrentUser, module: ModuleKey | None = None
) -> list[CodeGroupOut]:
    stmt = (
        select(CodeGroup)
        .where(CodeGroup.deleted_at.is_(None))
        .options(selectinload(CodeGroup.items))
        .order_by(CodeGroup.module, CodeGroup.code)
    )
    if module:
        stmt = stmt.where(CodeGroup.module == module)
    return [_group_out(g) for g in db.scalars(stmt).all()]


@router.get("/codes/{group_code}", response_model=CodeGroupOut)
def get_code_group(group_code: str, db: DbSession, _: CurrentUser) -> CodeGroupOut:
    group = _load_group_by_code(db, group_code)
    return _group_out(group)


@router.post("/codes", response_model=CodeGroupOut, status_code=status.HTTP_201_CREATED)
def create_code_group(
    payload: CodeGroupCreate, db: DbSession, _: AdminUser
) -> CodeGroupOut:
    if db.scalar(select(CodeGroup.id).where(CodeGroup.code == payload.code)):
        raise AppError("CODE_TAKEN", "이미 사용 중인 분류 코드입니다.", status.HTTP_409_CONFLICT)
    group = CodeGroup(**payload.model_dump())
    db.add(group)
    db.commit()
    db.refresh(group)
    return _group_out(group)


@router.patch("/codes/{group_id}", response_model=CodeGroupOut)
def update_code_group(
    group_id: uuid.UUID, payload: CodeGroupUpdate, db: DbSession, _: AdminUser
) -> CodeGroupOut:
    group = _load_group(db, group_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(group, field, value)
    db.commit()
    db.refresh(group)
    return _group_out(group)


@router.delete("/codes/{group_id}", response_model=Message)
def delete_code_group(group_id: uuid.UUID, db: DbSession, _: AdminUser) -> Message:
    group = _load_group(db, group_id)
    if group.is_system:
        raise AppError(
            "SYSTEM_GROUP",
            "시스템 기본 분류는 삭제할 수 없습니다. 항목만 수정해 주세요.",
        )
    group.deleted_at = now_utc()
    db.commit()
    return Message(message="삭제되었습니다.")


@router.post(
    "/codes/{group_id}/items", response_model=CodeItemOut, status_code=status.HTTP_201_CREATED
)
def create_code_item(
    group_id: uuid.UUID, payload: CodeItemCreate, db: DbSession, _: AdminUser
) -> CodeItemOut:
    group = _load_group(db, group_id)
    if db.scalar(
        select(CodeItem.id).where(
            CodeItem.group_id == group.id, CodeItem.code == payload.code
        )
    ):
        raise AppError("CODE_TAKEN", "이미 사용 중인 항목 코드입니다.", status.HTTP_409_CONFLICT)
    item = CodeItem(group_id=group.id, **payload.model_dump())
    db.add(item)
    db.commit()
    db.refresh(item)
    return CodeItemOut.model_validate(item)


@router.patch("/codes/items/{item_id}", response_model=CodeItemOut)
def update_code_item(
    item_id: uuid.UUID, payload: CodeItemUpdate, db: DbSession, _: AdminUser
) -> CodeItemOut:
    item = db.scalar(select(CodeItem).where(CodeItem.id == item_id))
    if item is None:
        raise AppError("NOT_FOUND", "항목을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(item, field, value)
    db.commit()
    db.refresh(item)
    return CodeItemOut.model_validate(item)


@router.delete("/codes/items/{item_id}", response_model=Message)
def delete_code_item(item_id: uuid.UUID, db: DbSession, _: AdminUser) -> Message:
    """Soft-deactivated rather than removed: existing tickets and assets still
    point at this code and their statistics must keep resolving its name."""
    item = db.scalar(select(CodeItem).where(CodeItem.id == item_id))
    if item is None:
        raise AppError("NOT_FOUND", "항목을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    item.is_active = False
    item.deleted_at = now_utc()
    db.commit()
    return Message(message="항목이 비활성화되었습니다. 기존 데이터의 분류는 유지됩니다.")


@router.post("/codes/{group_id}/reorder", response_model=Message)
def reorder_code_items(
    group_id: uuid.UUID, payload: CodeItemReorder, db: DbSession, _: AdminUser
) -> Message:
    group = _load_group(db, group_id)
    items = {
        i.id: i
        for i in db.scalars(select(CodeItem).where(CodeItem.group_id == group.id)).all()
    }
    for order, item_id in enumerate(payload.item_ids, start=1):
        if item_id in items:
            items[item_id].sort_order = order
    db.commit()
    return Message(message="순서가 저장되었습니다.")


# ================================================================== departments
@router.get("/departments", response_model=list[DepartmentOut])
def list_departments(db: DbSession, _: CurrentUser) -> list[DepartmentOut]:
    rows = db.scalars(
        select(Department)
        .where(Department.deleted_at.is_(None))
        .order_by(Department.sort_order, Department.name)
    ).all()
    counts = dict(
        db.execute(
            select(User.department_id, func.count(User.id))
            .where(User.deleted_at.is_(None), User.status == UserStatus.APPROVED)
            .group_by(User.department_id)
        ).all()
    )
    out = []
    for r in rows:
        d = DepartmentOut.model_validate(r)
        d.user_count = counts.get(r.id, 0)
        out.append(d)
    return out


@router.post(
    "/departments", response_model=DepartmentOut, status_code=status.HTTP_201_CREATED
)
def create_department(
    payload: DepartmentCreate, db: DbSession, _: AdminUser
) -> DepartmentOut:
    dept = Department(**payload.model_dump())
    db.add(dept)
    db.commit()
    db.refresh(dept)
    return DepartmentOut.model_validate(dept)


@router.patch("/departments/{department_id}", response_model=DepartmentOut)
def update_department(
    department_id: uuid.UUID, payload: DepartmentUpdate, db: DbSession, _: AdminUser
) -> DepartmentOut:
    dept = db.scalar(
        select(Department).where(
            Department.id == department_id, Department.deleted_at.is_(None)
        )
    )
    if dept is None:
        raise AppError("NOT_FOUND", "부서를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    data = payload.model_dump(exclude_unset=True)
    if data.get("parent_id") == dept.id:
        raise AppError("INVALID_PARENT", "자기 자신을 상위 부서로 지정할 수 없습니다.")
    for field, value in data.items():
        setattr(dept, field, value)
    db.commit()
    db.refresh(dept)
    return DepartmentOut.model_validate(dept)


@router.delete("/departments/{department_id}", response_model=Message)
def delete_department(
    department_id: uuid.UUID, db: DbSession, _: AdminUser
) -> Message:
    dept = db.scalar(select(Department).where(Department.id == department_id))
    if dept is None:
        raise AppError("NOT_FOUND", "부서를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    in_use = db.scalar(
        select(func.count(User.id)).where(
            User.department_id == department_id, User.deleted_at.is_(None)
        )
    )
    if in_use:
        raise AppError("DEPARTMENT_IN_USE", f"소속 인원 {in_use}명이 있어 삭제할 수 없습니다.")
    dept.deleted_at = now_utc()
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== audit
@router.get("/audit-logs", response_model=list[AuditLogOut])
def list_audit_logs(
    db: DbSession,
    _: AdminUser,
    page: PageParams,
    action: AuditAction | None = None,
    module: ModuleKey | None = None,
    actor_id: uuid.UUID | None = None,
    entity_type: str | None = None,
    entity_id: str | None = None,
    q: Annotated[str | None, Query(description="summary contains")] = None,
) -> list[AuditLogOut]:
    stmt = select(AuditLog)
    if action:
        stmt = stmt.where(AuditLog.action == action)
    if module:
        stmt = stmt.where(AuditLog.module == module)
    if actor_id:
        stmt = stmt.where(AuditLog.actor_id == actor_id)
    if entity_type:
        stmt = stmt.where(AuditLog.entity_type == entity_type)
    if entity_id:
        stmt = stmt.where(AuditLog.entity_id == entity_id)
    if q:
        stmt = stmt.where(AuditLog.summary.ilike(f"%{q.strip()}%"))
    rows = db.scalars(
        stmt.order_by(AuditLog.created_at.desc()).offset(page.offset).limit(page.size)
    ).all()
    return [AuditLogOut.model_validate(r) for r in rows]


# ================================================================== health
@router.get("/health", response_model=HealthOut)
def health(db: DbSession, _: CurrentUser) -> HealthOut:
    try:
        db.execute(text("SELECT 1"))
        db_ok = True
    except Exception:  # noqa: BLE001 - health must report, not raise
        db_ok = False
    return HealthOut(
        status="ok" if db_ok else "degraded",
        version="0.1.0",
        environment=env.ENVIRONMENT,
        database=engine.dialect.name,
        database_ok=db_ok,
        uptime_seconds=round(time.monotonic() - STARTED_AT, 1),
        server_time=now_utc(),
    )


@router.get("/stats", response_model=SystemStats)
def system_stats(db: DbSession, _: AdminUser) -> SystemStats:
    """관리자 대시보드: 계정/데이터 현황과 테이블별 행 수."""
    live_user = User.deleted_at.is_(None)
    storage_bytes = 0
    if env.storage_path.exists():
        storage_bytes = sum(
            f.stat().st_size for f in env.storage_path.rglob("*") if f.is_file()
        )

    return SystemStats(
        users_total=db.scalar(select(func.count(User.id)).where(live_user)) or 0,
        users_pending=db.scalar(
            select(func.count(User.id)).where(live_user, User.status == UserStatus.PENDING)
        ) or 0,
        users_active=db.scalar(
            select(func.count(User.id)).where(live_user, User.status == UserStatus.APPROVED)
        ) or 0,
        tickets_total=db.scalar(
            select(func.count(ServiceTicket.id)).where(ServiceTicket.deleted_at.is_(None))
        ) or 0,
        tickets_open=db.scalar(
            select(func.count(ServiceTicket.id)).where(
                ServiceTicket.deleted_at.is_(None),
                ServiceTicket.status.in_(OPEN_SERVICE_STATUSES),
            )
        ) or 0,
        assets_total=db.scalar(
            select(func.count(Asset.id)).where(Asset.deleted_at.is_(None))
        ) or 0,
        posts_total=db.scalar(
            select(func.count(Post.id)).where(Post.deleted_at.is_(None))
        ) or 0,
        events_upcoming=db.scalar(
            select(func.count(Event.id)).where(
                Event.deleted_at.is_(None), Event.starts_at >= now_utc()
            )
        ) or 0,
        notifications_unsent=db.scalar(
            select(func.count(Notification.id)).where(Notification.is_read.is_(False))
        ) or 0,
        storage_bytes=storage_bytes,
        tables=_table_stats(db),
    )


def _table_stats(db: Session) -> list[TableStat]:
    out: list[TableStat] = []
    for name in sorted(inspect(engine).get_table_names()):
        try:
            n = db.scalar(text(f"SELECT COUNT(*) FROM {name}"))  # noqa: S608
        except Exception:  # noqa: BLE001
            n = -1
        out.append(TableStat(table=name, rows=int(n or 0)))
    return out


# ================================================================== helpers
def _load_group(db: Session, group_id: uuid.UUID) -> CodeGroup:
    group = db.scalar(
        select(CodeGroup).where(CodeGroup.id == group_id, CodeGroup.deleted_at.is_(None))
    )
    if group is None:
        raise AppError("NOT_FOUND", "분류 그룹을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    return group


def _load_group_by_code(db: Session, code: str) -> CodeGroup:
    group = db.scalar(
        select(CodeGroup)
        .where(CodeGroup.code == code, CodeGroup.deleted_at.is_(None))
        .options(selectinload(CodeGroup.items))
    )
    if group is None:
        raise AppError("NOT_FOUND", "분류 그룹을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    return group


def _group_out(group: CodeGroup) -> CodeGroupOut:
    out = CodeGroupOut.model_validate(group)
    out.items = [
        CodeItemOut.model_validate(i)
        for i in sorted(group.items, key=lambda i: i.sort_order)
        if i.deleted_at is None
    ]
    return out
