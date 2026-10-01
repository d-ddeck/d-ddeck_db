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
from sqlalchemy import func, inspect, or_, select, text
from sqlalchemy.orm import Session, selectinload

from app.core.config import settings as env
from app.core.database import engine
from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import AuditLog, CodeGroup, CodeItem, ModuleSetting
from app.models.base import Base
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
    CodeItemUsage,
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
from app.services import (
    asset_rules,
    audit,
    bootstrap,
    code_tree,
    operations,
    settings_store,
)
from app.version import VERSION

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
        settings=[
            SettingOut.model_validate(r)
            for r in rows
            if (r.module, r.key) in bootstrap.expected_setting_types()
        ],
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
    """What a 설정창 Save posts: the whole form at once, upserted by key.

    값은 선언된 타입으로 검증·변환해 저장한다. 알려진 키는 기본 설정표의 타입이 기준이고
    (화면이 보낸 value_type 이 달라도 표를 따른다), 모르는 키는 보낸 value_type 을 따른다.
    """
    expected = bootstrap.expected_setting_types()
    changes: dict[str, list] = {}
    for item in payload.settings:
        if (module, item.key) not in expected:
            raise AppError("UNKNOWN_SETTING", "지원하지 않는 설정입니다.", 400)
        vtype = expected[(module, item.key)]
        try:
            value = settings_store.normalize(item.key, item.value, vtype)
        except (TypeError, ValueError):
            raise AppError(
                "INVALID_SETTING_VALUE",
                f"'{item.label or item.key}' 값이 형식({vtype})에 맞지 않습니다.",
                details={"key": item.key, "value_type": vtype, "value": item.value},
            ) from None
        row = db.scalar(
            select(ModuleSetting).where(
                ModuleSetting.module == module, ModuleSetting.key == item.key
            )
        )
        if row is None:
            row = ModuleSetting(module=module, key=item.key)
            db.add(row)
            changes[item.key] = [None, value]
        elif row.value != value:
            changes[item.key] = [row.value, value]
        row.value = value
        row.value_type = vtype
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
def get_code_group(
    group_code: str, db: DbSession, _: CurrentUser, include_historical: bool = False
) -> CodeGroupOut:
    group = _load_group_by_code(db, group_code)
    if group_code == "SERVICE_RESPONDER":
        from app.services.service_responders import selectable

        items = selectable(db, group, include_historical=include_historical)
        out = _group_out(group)
        out.items = [_item_out(item, group) for item in items]
        return out
    return _group_out(group)


@router.post("/codes", response_model=CodeGroupOut, status_code=status.HTTP_201_CREATED)
def create_code_group(
    payload: CodeGroupCreate, db: DbSession, admin: AdminUser, client: Client
) -> CodeGroupOut:
    if db.scalar(select(CodeGroup.id).where(CodeGroup.code == payload.code)):
        raise AppError(
            "CODE_TAKEN", "이미 사용 중인 분류 코드입니다.", status.HTTP_409_CONFLICT
        )
    group = CodeGroup(**payload.model_dump())
    db.add(group)
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="group",
        entity_id=group.id,
        summary="create_code_group",
        client=client,
    )
    db.commit()
    db.refresh(group)
    return _group_out(group)


@router.patch("/codes/{group_id}", response_model=CodeGroupOut)
def update_code_group(
    group_id: uuid.UUID,
    payload: CodeGroupUpdate,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> CodeGroupOut:
    group = _load_group(db, group_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(group, field, value)
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="group",
        entity_id=group.id,
        summary="update_code_group",
        client=client,
    )
    db.commit()
    db.refresh(group)
    return _group_out(group)


@router.delete("/codes/{group_id}", response_model=Message)
def delete_code_group(
    group_id: uuid.UUID, db: DbSession, admin: AdminUser, client: Client
) -> Message:
    group = _load_group(db, group_id)
    if group.is_system:
        raise AppError(
            "SYSTEM_GROUP",
            "시스템 기본 분류는 삭제할 수 없습니다. 항목만 수정해 주세요.",
        )
    group.deleted_at = now_utc()
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="code_group",
        entity_id=group.id,
        summary="분류 그룹 삭제",
        client=client,
    )
    db.commit()
    return Message(message="삭제되었습니다.")


@router.post(
    "/codes/{group_id}/items",
    response_model=CodeItemOut,
    status_code=status.HTTP_201_CREATED,
)
def create_code_item(
    group_id: uuid.UUID,
    payload: CodeItemCreate,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> CodeItemOut:
    group = _load_group(db, group_id)
    existing = db.scalar(
        select(CodeItem).where(
            CodeItem.group_id == group.id, CodeItem.code == payload.code
        )
    )
    if existing is not None and existing.deleted_at is None:
        raise AppError(
            "CODE_TAKEN", "이미 사용 중인 항목 코드입니다.", status.HTTP_409_CONFLICT
        )
    parent_id = (
        existing.parent_id
        if existing is not None and "parent_id" not in payload.model_fields_set
        else payload.parent_id
    )
    code_tree.resolve_parent(db, group, parent_id)
    if existing is not None:
        # 같은 코드는 같은 분류다: 삭제된 줄을 되살려 옛 기록의 연결도 돌아오게 한다.
        # 함께 지워진 하위 항목(같은 시각)도 같이 돌아온다.
        removed_at = existing.deleted_at
        for child in db.scalars(
            select(CodeItem).where(
                CodeItem.parent_id == existing.id, CodeItem.deleted_at == removed_at
            )
        ).all():
            child.deleted_at = None
            child.is_active = True
        for field, value in payload.model_dump(exclude_unset=True).items():
            setattr(existing, field, value)
        existing.deleted_at = None
        existing.is_active = True
        item = existing
    else:
        item = CodeItem(group_id=group.id, **payload.model_dump())
        db.add(item)
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="item",
        entity_id=item.id,
        summary="create_code_item",
        client=client,
    )
    db.commit()
    db.refresh(item)
    return _item_out(item, group)


@router.patch("/codes/items/{item_id}", response_model=CodeItemOut)
def update_code_item(
    item_id: uuid.UUID,
    payload: CodeItemUpdate,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> CodeItemOut:
    item = _load_item(db, item_id)
    changes = payload.model_dump(exclude_unset=True)
    if "parent_id" in changes:
        code_tree.resolve_parent(db, item.group, changes["parent_id"])
    for field, value in changes.items():
        setattr(item, field, value)
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="item",
        entity_id=item.id,
        summary="update_code_item",
        client=client,
    )
    db.commit()
    db.refresh(item)
    return _item_out(item, item.group)


@router.get("/codes/items/{item_id}/usage", response_model=CodeItemUsage)
def code_item_usage(item_id: uuid.UUID, db: DbSession, _: AdminUser) -> CodeItemUsage:
    """삭제 확인 창용: 이 항목을 쓰는 기록이 몇 건인지, 지울 수 있는지."""
    item = _load_item(db, item_id)
    usage = _item_usage(db, item.id)
    reason = _protected_reason(item.group, item)
    return CodeItemUsage(
        count=sum(usage.values()),
        by=usage,
        children=_child_count(db, item.id),
        is_protected=reason is not None,
        protected_reason=reason,
    )


@router.delete("/codes/items/{item_id}", response_model=Message)
def delete_code_item(
    item_id: uuid.UUID, db: DbSession, admin: AdminUser, client: Client
) -> Message:
    """목록에서 없앤다(하위 항목도 함께). 줄은 soft delete 로 남겨 두어
    이미 이 분류를 쓰는 기록·장비·통계가 이름을 계속 보여 줄 수 있게 한다.
    같은 코드로 다시 추가하면 그 줄이 되살아난다."""
    item = _load_item(db, item_id)
    group = item.group
    reason = _protected_reason(group, item)
    if reason:
        raise AppError("SYSTEM_ITEM", reason)

    usage = _item_usage(db, item.id)
    children = db.scalars(
        select(CodeItem).where(
            CodeItem.parent_id == item.id, CodeItem.deleted_at.is_(None)
        )
    ).all()
    stamp = now_utc()
    for row in (item, *children):
        row.is_active = False
        row.deleted_at = stamp
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=admin,
        module=group.module,
        entity_type="code_item",
        entity_id=item.id,
        summary=f"분류 항목 삭제: {group.name} › {item.name}",
        changes={"usage": usage, "children": len(children)},
        client=client,
    )
    db.commit()

    used = sum(usage.values())
    message = f"'{item.name}' 항목을 삭제했습니다."
    if children:
        message += f" 하위 항목 {len(children)}개도 함께 삭제했습니다."
    if used:
        message += (
            f" 이 항목을 쓰던 기존 기록 {used}건은 분류 이름을 그대로 보여 줍니다."
        )
    return Message(message=message)


@router.post("/codes/{group_id}/reorder", response_model=Message)
def reorder_code_items(
    group_id: uuid.UUID,
    payload: CodeItemReorder,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> Message:
    group = _load_group(db, group_id)
    items = {
        i.id: i
        for i in db.scalars(select(CodeItem).where(CodeItem.group_id == group.id)).all()
    }
    for order, item_id in enumerate(payload.item_ids, start=1):
        if item_id in items:
            items[item_id].sort_order = order
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="group",
        entity_id=group.id,
        summary="reorder_code_items",
        client=client,
    )
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
    payload: DepartmentCreate, db: DbSession, admin: AdminUser, client: Client
) -> DepartmentOut:
    dept = Department(**payload.model_dump())
    db.add(dept)
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="dept",
        entity_id=dept.id,
        summary="create_department",
        client=client,
    )
    db.commit()
    db.refresh(dept)
    return DepartmentOut.model_validate(dept)


@router.patch("/departments/{department_id}", response_model=DepartmentOut)
def update_department(
    department_id: uuid.UUID,
    payload: DepartmentUpdate,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> DepartmentOut:
    dept = db.scalar(
        select(Department).where(
            Department.id == department_id, Department.deleted_at.is_(None)
        )
    )
    if dept is None:
        raise AppError(
            "NOT_FOUND", "부서를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    data = payload.model_dump(exclude_unset=True)
    if data.get("parent_id") == dept.id:
        raise AppError("INVALID_PARENT", "자기 자신을 상위 부서로 지정할 수 없습니다.")
    for field, value in data.items():
        setattr(dept, field, value)
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="dept",
        entity_id=dept.id,
        summary="update_department",
        client=client,
    )
    db.commit()
    db.refresh(dept)
    return DepartmentOut.model_validate(dept)


@router.delete("/departments/{department_id}", response_model=Message)
def delete_department(
    department_id: uuid.UUID, db: DbSession, admin: AdminUser, client: Client
) -> Message:
    dept = db.scalar(select(Department).where(Department.id == department_id))
    if dept is None:
        raise AppError(
            "NOT_FOUND", "부서를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    in_use = db.scalar(
        select(func.count(User.id)).where(
            User.department_id == department_id, User.deleted_at.is_(None)
        )
    )
    if in_use:
        raise AppError(
            "DEPARTMENT_IN_USE", f"소속 인원 {in_use}명이 있어 삭제할 수 없습니다."
        )
    dept.deleted_at = now_utc()
    db.flush()
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=admin,
        module=ModuleKey.SYSTEM,
        entity_type="dept",
        entity_id=dept.id,
        summary="delete_department",
        client=client,
    )
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
        version=VERSION,
        environment=env.ENVIRONMENT,
        database=engine.dialect.name,
        database_ok=db_ok,
        uptime_seconds=round(time.monotonic() - STARTED_AT, 1),
        server_time=now_utc(),
        **(operations.health_details(db) if db_ok else {}),
    )


@router.get("/backup")
def backup_status(_: AdminUser):
    return operations.backup_status()


@router.post("/backup", status_code=202)
def request_backup(db: DbSession, user: AdminUser, client: Client):
    from app.services.drive_backup import request_backup as request_google_backup
    request_google_backup()
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.SYSTEM,
        entity_type="backup",
        summary="Google 드라이브 백업 요청",
        client=client,
    )
    db.commit()
    return {
        "message": "Google 백업을 요청했습니다. Google 백업 페이지에서 결과를 확인하세요."
    }


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
            select(func.count(User.id)).where(
                live_user, User.status == UserStatus.PENDING
            )
        )
        or 0,
        users_active=db.scalar(
            select(func.count(User.id)).where(
                live_user, User.status == UserStatus.APPROVED
            )
        )
        or 0,
        tickets_total=db.scalar(
            select(func.count(ServiceTicket.id)).where(
                ServiceTicket.deleted_at.is_(None)
            )
        )
        or 0,
        tickets_open=db.scalar(
            select(func.count(ServiceTicket.id)).where(
                ServiceTicket.deleted_at.is_(None),
                ServiceTicket.status.in_(OPEN_SERVICE_STATUSES),
            )
        )
        or 0,
        assets_total=db.scalar(
            select(func.count(Asset.id)).where(Asset.deleted_at.is_(None))
        )
        or 0,
        posts_total=db.scalar(
            select(func.count(Post.id)).where(Post.deleted_at.is_(None))
        )
        or 0,
        events_upcoming=db.scalar(
            select(func.count(Event.id)).where(
                Event.deleted_at.is_(None), Event.starts_at >= now_utc()
            )
        )
        or 0,
        notifications_unsent=db.scalar(
            select(func.count(Notification.id)).where(Notification.is_read.is_(False))
        )
        or 0,
        storage_bytes=storage_bytes,
        tables=_table_stats(db),
    )


def _table_stats(db: Session) -> list[TableStat]:
    out: list[TableStat] = []
    for name in sorted(inspect(engine).get_table_names()):
        try:
            n = db.scalar(text(f"SELECT COUNT(*) FROM {name}"))
        except Exception:  # noqa: BLE001
            n = -1
        out.append(TableStat(table=name, rows=int(n or 0)))
    return out


# ================================================================== helpers
def _load_group(db: Session, group_id: uuid.UUID) -> CodeGroup:
    group = db.scalar(
        select(CodeGroup).where(
            CodeGroup.id == group_id, CodeGroup.deleted_at.is_(None)
        )
    )
    if group is None:
        raise AppError(
            "NOT_FOUND", "분류 그룹을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return group


def _load_group_by_code(db: Session, code: str) -> CodeGroup:
    group = db.scalar(
        select(CodeGroup)
        .where(CodeGroup.code == code, CodeGroup.deleted_at.is_(None))
        .options(selectinload(CodeGroup.items))
    )
    if group is None:
        raise AppError(
            "NOT_FOUND", "분류 그룹을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return group


def _group_out(group: CodeGroup) -> CodeGroupOut:
    out = CodeGroupOut.model_validate(group)
    out.parent_group_code = code_tree.parent_group_code(group.code)
    out.items = [
        _item_out(i, group)
        for i in sorted(group.items, key=lambda i: i.sort_order)
        if i.deleted_at is None
    ]
    return out


def _item_out(item: CodeItem, group: CodeGroup) -> CodeItemOut:
    out = CodeItemOut.model_validate(item)
    out.is_protected = _protected_reason(group, item) is not None
    return out


def _load_item(db: Session, item_id: uuid.UUID) -> CodeItem:
    item = db.scalar(
        select(CodeItem)
        .where(CodeItem.id == item_id, CodeItem.deleted_at.is_(None))
        .options(selectinload(CodeItem.group))
    )
    if item is None:
        raise AppError(
            "NOT_FOUND", "항목을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return item


# 재고 상태 중 서버 로직이 기대는 규칙. 'free'(회수·폐기)는 지워도 된다.
_PROTECTED_RULES = {"store", "as", "clear"}


def _protected_reason(group: CodeGroup, item: CodeItem) -> str | None:
    if group.code != asset_rules.STATUS_GROUP:
        return None
    if asset_rules.rule_of(item).kind not in _PROTECTED_RULES:
        return None
    return (
        "재고 상태 규칙(매장 필수 · AS · 창고 자동 비움)에 쓰이는 항목이라 삭제할 수 없습니다. "
        "이름만 바꾸거나 비활성화해 주세요."
    )


# 사용처 표의 한글 이름. 없는 표는 표 이름 그대로.
_USAGE_LABELS = {
    "service_tickets": "대응 기록",
    "service_ticket_causes": "대응 원인",
    "service_ticket_responders": "대응 인원",
    "stores": "매장",
    "assets": "장비",
    "asset_movements": "장비 이동 이력",
    "events": "일정",
}


def _item_usage(db: Session, item_id: uuid.UUID) -> dict[str, int]:
    """code_items 를 가리키는 모든 외래키 열을 훑어 이 항목을 쓰는 줄 수를 센다.
    표가 늘어도 손볼 곳이 없도록 메타데이터에서 찾는다."""
    out: dict[str, int] = {}
    for table in Base.metadata.sorted_tables:
        if table.name == CodeItem.__tablename__:
            continue  # 하위 항목은 따로 센다
        cols = [
            c
            for c in table.columns
            if any(
                fk.column.table.name == CodeItem.__tablename__ for fk in c.foreign_keys
            )
        ]
        if not cols:
            continue
        stmt = (
            select(func.count())
            .select_from(table)
            .where(or_(*[c == item_id for c in cols]))
        )
        if "deleted_at" in table.c:
            stmt = stmt.where(table.c.deleted_at.is_(None))
        n = int(db.scalar(stmt) or 0)
        if n:
            out[_USAGE_LABELS.get(table.name, table.name)] = n
    return out


def _child_count(db: Session, item_id: uuid.UUID) -> int:
    return int(
        db.scalar(
            select(func.count())
            .select_from(CodeItem)
            .where(CodeItem.parent_id == item_id, CodeItem.deleted_at.is_(None))
        )
        or 0
    )


@router.delete("/history/{kind}/{identifier}", response_model=Message)
def hide_history(
    kind: str, identifier: uuid.UUID, db: DbSession, user: AdminUser, client: Client
):
    """Local-console cleanup: retain source rows for stock/rental integrity and audit."""
    from ipaddress import ip_address

    from app.models.inventory import AssetMovement

    try:
        local = ip_address(client.ip or "").is_loopback
    except ValueError:
        local = False
    if not local:
        raise AppError(
            "LOCAL_ADMIN_REQUIRED",
            "이력 정리는 서버 PC의 localhost로 접속한 관리자만 가능합니다.",
            403,
        )
    model = {"audit": AuditLog, "movement": AssetMovement}.get(kind)
    if model is None:
        raise AppError("HISTORY_NOT_FOUND", "이력을 찾을 수 없습니다.", 404)
    row = db.get(model, identifier)
    if row is None or row.hidden_at is not None:
        raise AppError("HISTORY_NOT_FOUND", "이력을 찾을 수 없습니다.", 404)
    if kind == "audit" and row.entity_type != "service_ticket":
        raise AppError("HISTORY_PROTECTED", "대응 수정 이력만 정리할 수 있습니다.", 403)
    row.hidden_at = now_utc()
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=user,
        module=ModuleKey.SYSTEM,
        entity_type="history_cleanup",
        entity_id=identifier,
        summary=f"로컬 관리자 이력 목록 정리 ({kind}); 원본 보존",
        client=client,
    )
    db.commit()
    return Message(message="이력 목록에서 제거했습니다. 원본과 재고 참조는 보존됩니다.")
