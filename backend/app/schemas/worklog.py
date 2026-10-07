"""근무일지 payloads."""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Any, ClassVar

from pydantic import BaseModel, Field

from app.models.enums import WorkLogVisibility
from app.schemas.common import ORMModel, PatchModel, UserBrief


class WorkLogCreate(BaseModel):
    work_date: date
    work_start: str = Field(pattern=r"^\d{2}:\d{2}$", description="HH:MM")
    work_end: str = Field(pattern=r"^\d{2}:\d{2}$")
    summary: str = Field(
        min_length=1, description="한 줄에 하나씩. 서버가 1. 2. 번호를 다시 매긴다"
    )
    detail: str = Field(min_length=1)
    morning: str | None = None
    afternoon: str | None = None
    overtime: bool = False
    overtime_note: str | None = Field(None, max_length=200)
    plan: str | None = None
    needs: str | None = None
    visibility: WorkLogVisibility = WorkLogVisibility.PRIVATE
    # 계정에 직급이 있으면 무시하고 계정 직급을 쓴다. 없으면 필수.
    position: str | None = Field(None, max_length=50)


class WorkLogUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {
        "work_date",
        "work_start",
        "work_end",
        "detail",
        "visibility",
        "overtime",
        "summary",
    }

    work_date: date | None = None
    work_start: str | None = Field(None, pattern=r"^\d{2}:\d{2}$")
    work_end: str | None = Field(None, pattern=r"^\d{2}:\d{2}$")
    summary: str | None = Field(None, min_length=1)
    detail: str | None = Field(None, min_length=1)
    morning: str | None = None
    afternoon: str | None = None
    overtime: bool | None = None
    overtime_note: str | None = Field(None, max_length=200)
    plan: str | None = None
    needs: str | None = None
    visibility: WorkLogVisibility | None = None
    position: str | None = Field(None, max_length=50)


class WorkLogOut(ORMModel):
    id: uuid.UUID
    author_id: uuid.UUID | None = None
    author_name: str
    position: str | None = None
    work_date: date
    work_start: str
    work_end: str
    summary: str
    detail: str
    morning: str | None = None
    afternoon: str | None = None
    overtime: bool
    overtime_note: str | None = None
    plan: str | None = None
    needs: str | None = None
    visibility: WorkLogVisibility
    legacy_id: int | None = None
    created_by_id: uuid.UUID | None = None
    created_at: datetime
    updated_at: datetime
    attachment_count: int = 0
    can_edit: bool = False
    overtime_minutes: int = 0


class OvertimeDay(BaseModel):
    id: uuid.UUID
    work_date: date
    work_start: str
    work_end: str
    minutes: int
    reason: str | None = None


class OvertimeSummary(BaseModel):
    year: int
    month: int
    items: list[OvertimeDay]
    total_minutes: int


class WorkLogDetail(WorkLogOut):
    author: UserBrief | None = None
    created_by: UserBrief | None = None
    updated_by: UserBrief | None = None


class WorkLogDraftIn(BaseModel):
    data: dict[str, Any] = Field(description="폼 칸 그대로 (검사하지 않는다)")


class WorkLogDraftOut(BaseModel):
    data: dict[str, Any]
    saved_at: datetime


class WorkLogLookups(BaseModel):
    positions: list[str] = Field(description="직급 목록 (WORKLOG_POSITION)")
    fixed_position: str | None = Field(
        None, description="계정에 지정된 직급. 있으면 폼에서 못 바꾼다"
    )
    author_name: str
    default_work_start: str
    default_work_end: str
    authors: list[UserBrief] = Field(description="볼 수 있는 범위의 작성자")
    years: list[int]
    draft: WorkLogDraftOut | None = None
