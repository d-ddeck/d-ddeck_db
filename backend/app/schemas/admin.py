"""관리기능 payloads: module settings, code master, audit log, health."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, ClassVar

from pydantic import BaseModel, Field

from app.models.enums import AuditAction, ModuleKey
from app.schemas.common import ORMModel, PatchModel


# ---------------------------------------------------------------- settings
class SettingUpsert(BaseModel):
    """One row of a 설정창 form."""

    key: str = Field(min_length=1, max_length=100)
    value: Any = None
    value_type: str = Field("string", pattern="^(string|int|float|bool|json|list)$")
    label: str | None = Field(None, max_length=200)
    description: str | None = None
    is_public: bool = False


class SettingBulkUpsert(BaseModel):
    """What the 설정창 Save button posts: the whole form in one request."""

    settings: list[SettingUpsert]


class SettingOut(ORMModel):
    id: uuid.UUID
    module: ModuleKey
    key: str
    value: Any = None
    value_type: str
    label: str | None = None
    description: str | None = None
    is_public: bool
    updated_at: datetime


class ModuleSettingsOut(BaseModel):
    """Everything one 설정창 needs in a single GET."""

    module: ModuleKey
    settings: list[SettingOut]
    code_groups: list[CodeGroupOut] = Field(default_factory=list)


# ---------------------------------------------------------------- code master
class CodeGroupCreate(BaseModel):
    code: str = Field(min_length=1, max_length=60)
    name: str = Field(min_length=1, max_length=100)
    module: ModuleKey
    description: str | None = None


class CodeGroupUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {"name"}

    name: str | None = Field(None, max_length=100)
    description: str | None = None


class CodeItemCreate(BaseModel):
    code: str = Field(min_length=1, max_length=60)
    name: str = Field(min_length=1, max_length=120)
    parent_id: uuid.UUID | None = None
    color: str | None = Field(None, max_length=20)
    sort_order: int = 0
    extra: dict | None = None


class CodeItemUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {"name", "sort_order", "is_active"}

    name: str | None = Field(None, max_length=120)
    parent_id: uuid.UUID | None = None
    color: str | None = Field(None, max_length=20)
    sort_order: int | None = None
    is_active: bool | None = None
    extra: dict | None = None


class CodeItemOut(ORMModel):
    id: uuid.UUID
    group_id: uuid.UUID
    parent_id: uuid.UUID | None = None
    code: str
    name: str
    color: str | None = None
    sort_order: int
    is_active: bool
    extra: dict | None = None
    # 재고 상태 규칙(매장 필수·AS·창고 자동 비움)에 쓰이는 항목은 삭제할 수 없다.
    is_protected: bool = False


class CodeItemUsage(BaseModel):
    """삭제 확인 창에 보여 줄 것: 이 항목을 쓰는 기록 수와 삭제 가능 여부."""

    count: int
    by: dict[str, int] = Field(default_factory=dict)
    children: int = 0
    is_protected: bool = False
    protected_reason: str | None = None


class CodeGroupOut(ORMModel):
    id: uuid.UUID
    code: str
    name: str
    module: ModuleKey
    description: str | None = None
    is_system: bool
    # 이 그룹이 어느 그룹의 하위 선택지인지 (증상 → 서비스 분류, 모델·제조사 → 자산 분류).
    # 있으면 항목마다 parent_id 가 그 그룹의 항목을 가리켜야 한다.
    parent_group_code: str | None = None
    items: list[CodeItemOut] = Field(default_factory=list)


class CodeItemReorder(BaseModel):
    """Drag-and-drop reorder: send the ids in their new order."""

    item_ids: list[uuid.UUID]


# ---------------------------------------------------------------- departments
class DepartmentCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    code: str | None = Field(None, max_length=50)
    parent_id: uuid.UUID | None = None
    sort_order: int = 0


class DepartmentUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {"name", "sort_order"}

    name: str | None = Field(None, max_length=100)
    code: str | None = Field(None, max_length=50)
    parent_id: uuid.UUID | None = None
    sort_order: int | None = None


class DepartmentOut(ORMModel):
    id: uuid.UUID
    name: str
    code: str | None = None
    parent_id: uuid.UUID | None = None
    sort_order: int
    user_count: int = 0


# ---------------------------------------------------------------- audit / health
class AuditLogOut(ORMModel):
    id: uuid.UUID
    created_at: datetime
    actor_id: uuid.UUID | None = None
    actor_email: str | None = None
    action: AuditAction
    module: ModuleKey | None = None
    entity_type: str | None = None
    entity_id: str | None = None
    summary: str | None = None
    changes: dict | None = None
    ip_address: str | None = None
    user_agent: str | None = None


class TableStat(BaseModel):
    table: str
    rows: int


class HealthOut(BaseModel):
    status: str
    version: str
    environment: str
    database: str = Field(description="dialect name, e.g. sqlite or postgresql")
    database_ok: bool
    uptime_seconds: float
    server_time: datetime
    schema_revisions: list[str] = Field(default_factory=list)
    disk_free_bytes: int = 0
    backup: dict = Field(default_factory=dict)


class SystemStats(BaseModel):
    users_total: int
    users_pending: int
    users_active: int
    tickets_total: int
    tickets_open: int
    assets_total: int
    posts_total: int
    events_upcoming: int
    notifications_unsent: int
    storage_bytes: int
    tables: list[TableStat]


ModuleSettingsOut.model_rebuild()
