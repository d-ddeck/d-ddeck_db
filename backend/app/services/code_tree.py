"""분류 항목의 상하 관계.

증상(SERVICE_SYMPTOM)은 서비스 분류(SERVICE_CATEGORY)의 하위 선택지,
자산 모델(ASSET_MODEL) · 자산 제조사(ASSET_MAKER)는 자산 분류(ASSET_CATEGORY)의
하위 선택지다. 그룹 표에는 이 관계가 없고 항목의 parent_id 로만 남으므로, 어떤
그룹이 어느 그룹의 하위인지는 여기서 한 번만 적는다. 관리 화면은 이 정보로
상위를 먼저 고르게 하고, 서버는 하위 항목에 상위가 빠지거나 다른 분류를 가리키는
것을 거절한다.
"""
from __future__ import annotations

import uuid

from fastapi import status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.models.admin import CodeGroup, CodeItem

PARENT_GROUP: dict[str, str] = {
    "SERVICE_SYMPTOM": "SERVICE_CATEGORY",
    "ASSET_MODEL": "ASSET_CATEGORY",
    "ASSET_MAKER": "ASSET_CATEGORY",
}


def parent_group_code(group_code: str) -> str | None:
    return PARENT_GROUP.get(group_code)


def resolve_parent(
    db: Session, group: CodeGroup, parent_id: uuid.UUID | None
) -> CodeItem | None:
    """항목을 만들거나 상위를 바꿀 때 parent_id 가 규칙에 맞는지 본다.

    하위 그룹이면 상위 필수(PARENT_REQUIRED)이고 상위 그룹의 살아 있는 항목이어야
    한다(PARENT_MISMATCH). 최상위 그룹은 같은 그룹 안 항목만 상위로 둘 수 있다.
    """
    want = PARENT_GROUP.get(group.code)
    if want is None:
        if parent_id is None:
            return None
        parent = _alive(db, parent_id)
        if parent is None or parent.group_id != group.id:
            raise AppError("PARENT_MISMATCH", "상위 항목은 같은 분류 안의 항목이어야 합니다.")
        return parent

    parent_group = db.scalar(select(CodeGroup).where(CodeGroup.code == want))
    parent_name = parent_group.name if parent_group else want
    if parent_id is None:
        raise AppError(
            "PARENT_REQUIRED",
            f"'{group.name}' 항목은 상위 '{parent_name}' 을(를) 먼저 골라야 합니다.",
        )
    parent = _alive(db, parent_id)
    if parent is None or parent_group is None or parent.group_id != parent_group.id:
        raise AppError(
            "PARENT_MISMATCH",
            f"'{group.name}' 항목의 상위는 '{parent_name}' 의 항목이어야 합니다.",
            status.HTTP_400_BAD_REQUEST,
        )
    return parent


def _alive(db: Session, item_id: uuid.UUID) -> CodeItem | None:
    return db.scalar(
        select(CodeItem).where(CodeItem.id == item_id, CodeItem.deleted_at.is_(None))
    )
