"""첨부 대상(entity)별 접근 규칙.

`/files` 는 모든 모듈이 같이 쓰므로, 첨부를 보거나 붙일 수 있는지는 그 첨부가 달린
본문의 규칙을 따라야 한다. 이 표가 없으면 비공개 근무일지·비밀글의 첨부가 id 만 알면
열리고, 존재하지 않는 대상에도 파일을 붙일 수 있다.

각 규칙은 해당 라우터의 본문 접근 규칙(worklog._can_view, board._require_secret_access …)
과 같게 유지한다. 라우터를 import 하면 순환이 생기므로 여기서 모델로 직접 판단한다.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable

from fastapi import status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.models.board import Board, Post
from app.models.calendar import Event, EventParticipant
from app.models.enums import ROLE_LEVEL, PostStatus, Role
from app.models.inventory import Asset
from app.models.service import ServiceTicket
from app.models.store import Store
from app.models.user import User
from app.models.worklog import WorkLog
from app.services import worklog_access


def check(
    db: Session, user: User, entity_type: str, entity_id: uuid.UUID, *, write: bool
) -> None:
    """읽기(write=False) 또는 첨부 추가(write=True) 권한이 없으면 AppError."""
    rule = RULES.get(entity_type)
    if rule is None:
        raise AppError("BAD_ENTITY", f"지원하지 않는 첨부 대상입니다: {entity_type}")
    rule(db, user, entity_id, write)


def _at_least(user: User, role: Role) -> bool:
    return ROLE_LEVEL[user.role] >= ROLE_LEVEL[role]


def _not_found() -> AppError:
    return AppError(
        "NOT_FOUND", "첨부 대상을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
    )


def _forbidden(message: str = "이 첨부에 접근할 권한이 없습니다.") -> AppError:
    return AppError("FORBIDDEN", message, status.HTTP_403_FORBIDDEN)


def _live(db: Session, model, entity_id: uuid.UUID):
    obj = db.scalar(
        select(model).where(model.id == entity_id, model.deleted_at.is_(None))
    )
    if obj is None:
        raise _not_found()
    return obj


# 대응 기록 · 장비 · 매장: 존재하면 로그인한 누구나 (구 서버와 같다).
def _service_ticket(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    _live(db, ServiceTicket, entity_id)


def _asset(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    _live(db, Asset, entity_id)


def _store(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    _live(db, Store, entity_id)


def _user(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    target = _live(db, User, entity_id)
    if target.id != user.id and not _at_least(user, Role.ADMIN):
        raise _forbidden("다른 사람의 계정 첨부에는 접근할 수 없습니다.")


def _post(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    post = _live(db, Post, entity_id)
    board = db.scalar(
        select(Board).where(Board.id == post.board_id, Board.deleted_at.is_(None))
    )
    if board is None:
        raise _not_found()
    owner_or_manager = post.author_id == user.id or _at_least(user, Role.MANAGER)
    if not _at_least(user, board.read_role):
        raise _forbidden("이 게시판을 볼 권한이 없습니다.")
    if post.status != PostStatus.PUBLISHED and not owner_or_manager:
        raise _not_found()
    if post.is_secret and not owner_or_manager:
        raise _forbidden("비밀글입니다.")
    if write:
        if not board.allow_attachment:
            raise _forbidden("첨부를 허용하지 않는 게시판입니다.")
        if not _at_least(user, board.write_role):
            raise _forbidden("이 게시판에 글을 쓸 권한이 없습니다.")
        if not owner_or_manager:
            raise _forbidden("본인 글에만 첨부할 수 있습니다.")


def _worklog(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    log = _live(db, WorkLog, entity_id)
    if write:
        if not worklog_access.can_edit(log, user):
            raise _forbidden("본인 근무일지에만 첨부할 수 있습니다.")
        return
    if not worklog_access.can_view(db, log, user):
        raise _forbidden("작성자, 같은 부서 팀장, 관리자만 볼 수 있는 근무일지입니다.")


def _event(db: Session, user: User, entity_id: uuid.UUID, write: bool) -> None:
    event = _live(db, Event, entity_id)
    manager = _at_least(user, Role.MANAGER)
    if write:
        if event.created_by_id != user.id and not manager:
            raise _forbidden("일정 작성자만 첨부할 수 있습니다.")
        return
    if not event.is_private or manager or event.created_by_id == user.id:
        return
    involved = db.scalar(
        select(EventParticipant.id).where(
            EventParticipant.event_id == event.id, EventParticipant.user_id == user.id
        )
    )
    if involved is None:
        raise _forbidden("비공개 일정입니다.")


RULES: dict[str, Callable[[Session, User, uuid.UUID, bool], None]] = {
    "service_ticket": _service_ticket,
    "asset": _asset,
    "post": _post,
    "event": _event,
    "user": _user,
    "store": _store,
    "worklog": _worklog,
}

ENTITY_TYPES = frozenset(RULES)
