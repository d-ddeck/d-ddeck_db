"""근무일지 열람 규칙 (고정): 작성자·등록한 계정, 같은 부서 팀장, 관리자·최고 관리자.

공개 범위를 고르는 기능은 없다. 본문·목록·PDF·첨부가 모두 이 규칙을 따른다.
"""

from __future__ import annotations

from sqlalchemy import or_, select, true
from sqlalchemy.orm import Session

from app.models.enums import ROLE_LEVEL, Role
from app.models.user import User
from app.models.worklog import WorkLog


def is_admin(user: User) -> bool:
    return ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.ADMIN]


def is_department_leader(user: User) -> bool:
    return user.role == Role.MANAGER and user.department_id is not None


def can_edit(log: WorkLog, user: User) -> bool:
    return is_admin(user) or log.author_id == user.id or log.created_by_id == user.id


def can_view(db: Session, log: WorkLog, user: User) -> bool:
    if can_edit(log, user):
        return True
    if is_department_leader(user) and log.author_id is not None:
        department = db.scalar(
            select(User.department_id).where(User.id == log.author_id)
        )
        return department == user.department_id
    return False


def mine_clause(user: User):
    return or_(WorkLog.author_id == user.id, WorkLog.created_by_id == user.id)


def visible_clause(user: User):
    """목록 조건: can_view 와 같은 규칙을 SQL 로."""
    if is_admin(user):
        return true()
    if is_department_leader(user):
        members = select(User.id).where(User.department_id == user.department_id)
        return or_(mine_clause(user), WorkLog.author_id.in_(members))
    return mine_clause(user)
