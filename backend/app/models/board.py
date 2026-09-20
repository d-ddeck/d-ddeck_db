"""게시판 module. A Board row *is* that board's settings record."""
from __future__ import annotations

import uuid

from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import (
    AuthorMixin,
    Base,
    SoftDeleteMixin,
    TimestampMixin,
    UUIDMixin,
    enum_type,
)
from app.models.enums import BoardType, PostStatus, Role


class Board(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "boards"

    code: Mapped[str] = mapped_column(String(60), unique=True, index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    type: Mapped[BoardType] = mapped_column(
        enum_type(BoardType), default=BoardType.FREE, nullable=False
    )
    description: Mapped[str | None] = mapped_column(Text)

    # --- fields the 게시판 설정창 edits ---
    read_role: Mapped[Role] = mapped_column(enum_type(Role), default=Role.MEMBER, nullable=False)
    write_role: Mapped[Role] = mapped_column(enum_type(Role), default=Role.MEMBER, nullable=False)
    allow_comment: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    allow_attachment: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    allow_secret: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    notify_on_post: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    page_size: Mapped[int] = mapped_column(Integer, default=20, nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    posts: Mapped[list["Post"]] = relationship(back_populates="board")


class Post(UUIDMixin, TimestampMixin, SoftDeleteMixin, AuthorMixin, Base):
    __tablename__ = "posts"

    board_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("boards.id", ondelete="CASCADE"), nullable=False, index=True
    )
    title: Mapped[str] = mapped_column(String(250), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False, default="")
    author_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    status: Mapped[PostStatus] = mapped_column(
        enum_type(PostStatus), default=PostStatus.PUBLISHED, nullable=False, index=True
    )
    is_pinned: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    is_secret: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    view_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    comment_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    board: Mapped["Board"] = relationship(back_populates="posts")
    comments: Mapped[list["PostComment"]] = relationship(
        back_populates="post", cascade="all, delete-orphan"
    )


class PostComment(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "post_comments"

    post_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("posts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("post_comments.id", ondelete="CASCADE")
    )
    author_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    content: Mapped[str] = mapped_column(Text, nullable=False)
    is_secret: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    post: Mapped["Post"] = relationship(back_populates="comments")
