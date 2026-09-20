"""게시판 module: board setup (the settings screen), posts and comments."""
from __future__ import annotations

import uuid

from fastapi import APIRouter, status
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.core.deps import AdminUser, Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.board import Board, Post, PostComment
from app.models.enums import (
    ROLE_LEVEL,
    AuditAction,
    ModuleKey,
    NotificationType,
    PostStatus,
    Role,
)
from app.models.user import User
from app.schemas.board import (
    BoardCreate,
    BoardOut,
    BoardUpdate,
    CommentCreate,
    CommentOut,
    CommentUpdate,
    PostCreate,
    PostDetail,
    PostListItem,
    PostUpdate,
)
from app.schemas.common import Message, Page, UserBrief
from app.services import audit, notifications

router = APIRouter(prefix="/board", tags=["board"])


# ================================================================== boards
@router.get("/boards", response_model=list[BoardOut])
def list_boards(db: DbSession, user: CurrentUser) -> list[BoardOut]:
    """Only the boards this user may read, so the nav never shows a dead tab."""
    rows = db.scalars(
        select(Board)
        .where(Board.deleted_at.is_(None), Board.is_active.is_(True))
        .order_by(Board.sort_order, Board.name)
    ).all()
    return [
        BoardOut.model_validate(b)
        for b in rows
        if ROLE_LEVEL[user.role] >= ROLE_LEVEL[b.read_role]
    ]


@router.post("/boards", response_model=BoardOut, status_code=status.HTTP_201_CREATED)
def create_board(
    payload: BoardCreate, db: DbSession, admin: AdminUser, client: Client
) -> BoardOut:
    if db.scalar(select(Board.id).where(Board.code == payload.code)):
        raise AppError("CODE_TAKEN", "이미 사용 중인 게시판 코드입니다.", status.HTTP_409_CONFLICT)
    board = Board(**payload.model_dump())
    db.add(board)
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=admin,
        module=ModuleKey.BOARD,
        entity_type="board",
        summary=f"게시판 생성: {board.name}",
        client=client,
    )
    db.commit()
    db.refresh(board)
    return BoardOut.model_validate(board)


@router.patch("/boards/{board_id}", response_model=BoardOut)
def update_board(
    board_id: uuid.UUID,
    payload: BoardUpdate,
    db: DbSession,
    admin: AdminUser,
    client: Client,
) -> BoardOut:
    """This endpoint is the 게시판 설정창 save."""
    board = _load_board(db, board_id)
    data = payload.model_dump(exclude_unset=True)
    before = {k: getattr(board, k) for k in data}
    for field, value in data.items():
        setattr(board, field, value)
    audit.record(
        db,
        action=AuditAction.SETTING_CHANGE,
        actor=admin,
        module=ModuleKey.BOARD,
        entity_type="board",
        entity_id=board.id,
        summary=f"게시판 설정 변경: {board.name}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    db.refresh(board)
    return BoardOut.model_validate(board)


@router.delete("/boards/{board_id}", response_model=Message)
def delete_board(board_id: uuid.UUID, db: DbSession, admin: AdminUser) -> Message:
    board = _load_board(db, board_id)
    board.deleted_at = now_utc()
    board.is_active = False
    db.commit()
    return Message(message="게시판이 삭제되었습니다.")


# ================================================================== posts
@router.get("/boards/{board_id}/posts", response_model=Page[PostListItem])
def list_posts(
    board_id: uuid.UUID,
    db: DbSession,
    user: CurrentUser,
    page: PageParams,
    q: str | None = None,
) -> Page[PostListItem]:
    board = _load_board(db, board_id)
    _require_read(board, user)

    stmt = select(Post).where(
        Post.board_id == board.id,
        Post.deleted_at.is_(None),
        Post.status == PostStatus.PUBLISHED,
    )
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(or_(Post.title.ilike(like), Post.content.ilike(like)))

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(Post.is_pinned.desc(), Post.created_at.desc())
        .offset(page.offset)
        .limit(page.size)
    ).all()
    return Page.build(
        [PostListItem.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.post(
    "/boards/{board_id}/posts", response_model=PostDetail, status_code=status.HTTP_201_CREATED
)
def create_post(
    board_id: uuid.UUID,
    payload: PostCreate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> PostDetail:
    board = _load_board(db, board_id)
    _require_write(board, user)
    if payload.is_secret and not board.allow_secret:
        raise AppError("SECRET_NOT_ALLOWED", "이 게시판은 비밀글을 허용하지 않습니다.")
    if payload.is_pinned and ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]:
        raise AppError("FORBIDDEN", "상단 고정 권한이 없습니다.", status.HTTP_403_FORBIDDEN)

    post = Post(
        board_id=board.id, author_id=user.id, created_by_id=user.id, **payload.model_dump()
    )
    db.add(post)
    db.flush()

    if board.notify_on_post and post.status == PostStatus.PUBLISHED:
        notifications.notify_all(
            db,
            type=NotificationType.SYSTEM,
            title=f"[{board.name}] {post.title}",
            body=post.content[:120] if post.content else None,
            payload={"route": "/board/post", "post_id": str(post.id)},
        )
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.BOARD,
        entity_type="post",
        entity_id=post.id,
        summary=f"게시글 작성 [{board.code}] {post.title}",
        client=client,
    )
    db.commit()
    return _post_detail(db, post.id, user)


@router.get("/posts/{post_id}", response_model=PostDetail)
def get_post(post_id: uuid.UUID, db: DbSession, user: CurrentUser) -> PostDetail:
    post = _load_post(db, post_id)
    board = _load_board(db, post.board_id)
    _require_read(board, user)
    _require_secret_access(post, user)

    # Views are counted per read; the author reading their own post does not count.
    if post.author_id != user.id:
        post.view_count += 1
        db.commit()
    return _post_detail(db, post_id, user)


@router.patch("/posts/{post_id}", response_model=PostDetail)
def update_post(
    post_id: uuid.UUID, payload: PostUpdate, db: DbSession, user: CurrentUser
) -> PostDetail:
    post = _load_post(db, post_id)
    _require_owner_or_manager(post, user)
    data = payload.model_dump(exclude_unset=True)
    if data.get("is_pinned") and ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]:
        raise AppError("FORBIDDEN", "상단 고정 권한이 없습니다.", status.HTTP_403_FORBIDDEN)
    for field, value in data.items():
        setattr(post, field, value)
    post.updated_by_id = user.id
    db.commit()
    return _post_detail(db, post_id, user)


@router.delete("/posts/{post_id}", response_model=Message)
def delete_post(
    post_id: uuid.UUID, db: DbSession, user: CurrentUser, client: Client
) -> Message:
    post = _load_post(db, post_id)
    _require_owner_or_manager(post, user)
    post.deleted_at = now_utc()
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=user,
        module=ModuleKey.BOARD,
        entity_type="post",
        entity_id=post.id,
        summary=f"게시글 삭제: {post.title}",
        client=client,
    )
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== comments
@router.post("/posts/{post_id}/comments", response_model=CommentOut)
def add_comment(
    post_id: uuid.UUID, payload: CommentCreate, db: DbSession, user: CurrentUser
) -> CommentOut:
    post = _load_post(db, post_id)
    board = _load_board(db, post.board_id)
    if not board.allow_comment:
        raise AppError("COMMENT_NOT_ALLOWED", "이 게시판은 댓글을 허용하지 않습니다.")
    _require_read(board, user)

    comment = PostComment(post_id=post.id, author_id=user.id, **payload.model_dump())
    db.add(comment)
    post.comment_count += 1

    if post.author_id and post.author_id != user.id:
        notifications.notify(
            db,
            user_ids=[post.author_id],
            type=NotificationType.BOARD_COMMENT,
            title="내 글에 댓글이 달렸습니다",
            body=f"{user.full_name}: {payload.content[:80]}",
            payload={"route": "/board/post", "post_id": str(post.id)},
            entity_type="post",
            entity_id=post.id,
        )
    db.commit()
    db.refresh(comment)
    return _comment_out(db, comment)


@router.patch("/comments/{comment_id}", response_model=CommentOut)
def update_comment(
    comment_id: uuid.UUID, payload: CommentUpdate, db: DbSession, user: CurrentUser
) -> CommentOut:
    comment = db.scalar(
        select(PostComment).where(
            PostComment.id == comment_id, PostComment.deleted_at.is_(None)
        )
    )
    if comment is None:
        raise AppError("NOT_FOUND", "댓글을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    if comment.author_id != user.id and ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]:
        raise AppError("FORBIDDEN", "수정 권한이 없습니다.", status.HTTP_403_FORBIDDEN)
    comment.content = payload.content
    db.commit()
    db.refresh(comment)
    return _comment_out(db, comment)


@router.delete("/comments/{comment_id}", response_model=Message)
def delete_comment(comment_id: uuid.UUID, db: DbSession, user: CurrentUser) -> Message:
    comment = db.scalar(
        select(PostComment).where(
            PostComment.id == comment_id, PostComment.deleted_at.is_(None)
        )
    )
    if comment is None:
        raise AppError("NOT_FOUND", "댓글을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    if comment.author_id != user.id and ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]:
        raise AppError("FORBIDDEN", "삭제 권한이 없습니다.", status.HTTP_403_FORBIDDEN)
    comment.deleted_at = now_utc()
    post = db.get(Post, comment.post_id)
    if post and post.comment_count > 0:
        post.comment_count -= 1
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== helpers
def _load_board(db: Session, board_id: uuid.UUID) -> Board:
    board = db.scalar(select(Board).where(Board.id == board_id, Board.deleted_at.is_(None)))
    if board is None:
        raise AppError("NOT_FOUND", "게시판을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    return board


def _load_post(db: Session, post_id: uuid.UUID) -> Post:
    post = db.scalar(select(Post).where(Post.id == post_id, Post.deleted_at.is_(None)))
    if post is None:
        raise AppError("NOT_FOUND", "게시글을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    return post


def _require_read(board: Board, user: User) -> None:
    if ROLE_LEVEL[user.role] < ROLE_LEVEL[board.read_role]:
        raise AppError("FORBIDDEN", "이 게시판을 볼 권한이 없습니다.", status.HTTP_403_FORBIDDEN)


def _require_write(board: Board, user: User) -> None:
    if ROLE_LEVEL[user.role] < ROLE_LEVEL[board.write_role]:
        raise AppError("FORBIDDEN", "이 게시판에 글을 쓸 권한이 없습니다.", status.HTTP_403_FORBIDDEN)


def _require_owner_or_manager(post: Post, user: User) -> None:
    if post.author_id != user.id and ROLE_LEVEL[user.role] < ROLE_LEVEL[Role.MANAGER]:
        raise AppError("FORBIDDEN", "본인 글만 수정/삭제할 수 있습니다.", status.HTTP_403_FORBIDDEN)


def _require_secret_access(post: Post, user: User) -> None:
    if not post.is_secret:
        return
    if post.author_id == user.id or ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.MANAGER]:
        return
    raise AppError("FORBIDDEN", "비밀글입니다.", status.HTTP_403_FORBIDDEN)


def _comment_out(db: Session, comment: PostComment) -> CommentOut:
    out = CommentOut.model_validate(comment)
    if comment.author_id:
        author = db.get(User, comment.author_id)
        out.author = UserBrief.model_validate(author) if author else None
    return out


def _post_detail(db: Session, post_id: uuid.UUID, user: User) -> PostDetail:
    post = _load_post(db, post_id)
    out = PostDetail.model_validate(post)
    if post.author_id:
        author = db.get(User, post.author_id)
        out.author = UserBrief.model_validate(author) if author else None

    comments = db.scalars(
        select(PostComment)
        .where(PostComment.post_id == post.id, PostComment.deleted_at.is_(None))
        .order_by(PostComment.created_at)
    ).all()
    visible = []
    for c in comments:
        # A secret comment is visible to its author, the post author and managers.
        if c.is_secret and not (
            c.author_id == user.id
            or post.author_id == user.id
            or ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.MANAGER]
        ):
            continue
        visible.append(_comment_out(db, c))
    out.comments = visible
    return out
