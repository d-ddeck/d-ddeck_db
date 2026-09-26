"""근무일지 module (구 서버 CS_Record 의 worklogs 를 옮긴 것).

작성자·일자마다 한 장. 직급, 근무시간, 업무 요약(줄마다 1. 2. 번호)·상세, 연장 근무,
예정 업무, 필요/요청사항, 공개 범위(비공개 = 나와 관리자 / 팀 공개 = 로그인한 모두).
첨부 파일은 공용 Attachment(entity_type="worklog") 를 쓴다.

임시 저장은 계정마다 한 장(WorkLogDraft): 쓰다 만 내용을 다른 기기에서 이어 쓴다.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Any

from sqlalchemy import Boolean, Date, ForeignKey, Index, Integer, String, Text, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import (
    AuthorMixin,
    Base,
    JSONType,
    SoftDeleteMixin,
    TimestampMixin,
    UTCDateTime,
    UUIDMixin,
    enum_type,
)
from app.models.enums import WorkLogVisibility


class WorkLog(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "worklogs"
    __table_args__ = (Index("ix_worklogs_author_date", "author_id", "work_date"),)

    # 작성자 계정. 구 서버는 이름 글자였고, 계정이 없는 이름도 있어 이름을 따로 둔다.
    author_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    author_name: Mapped[str] = mapped_column(String(80), nullable=False)
    position: Mapped[str | None] = mapped_column(
        String(50)
    )  # 직급 (계정 직급을 그대로)

    work_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    work_start: Mapped[str] = mapped_column(String(5), nullable=False)  # HH:MM
    work_end: Mapped[str] = mapped_column(String(5), nullable=False)

    summary: Mapped[str] = mapped_column(
        Text, nullable=False
    )  # 금일 업무 내용 요약 (번호 매김)
    detail: Mapped[str] = mapped_column(Text, nullable=False)  # 금일 근무 내용 상세
    overtime: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    overtime_note: Mapped[str | None] = mapped_column(String(200))
    plan: Mapped[str | None] = mapped_column(Text)  # 예정 업무
    needs: Mapped[str | None] = mapped_column(Text)  # 필요/요청사항
    visibility: Mapped[WorkLogVisibility] = mapped_column(
        enum_type(WorkLogVisibility), default=WorkLogVisibility.PRIVATE, nullable=False
    )

    # 구 서버 worklogs.id - 이관을 다시 돌려도 같은 장이 두 번 생기지 않게
    legacy_id: Mapped[int | None] = mapped_column(Integer, unique=True)


class WorkLogDraft(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "worklog_drafts"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    data: Mapped[Any] = mapped_column(JSONType, nullable=True)
    saved_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
