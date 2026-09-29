"""게시판 payloads. BoardCreate/BoardUpdate double as the board 설정창 form."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import ClassVar, Literal

from pydantic import BaseModel, Field

from app.models.enums import BoardType, PostStatus, Role
from app.schemas.common import ORMModel, PatchModel, UserBrief

BoardIcon = Literal["auto", "notice", "chat", "question", "folder", "calendar", "equipment", "store", "document", "task", "idea", "photo", "team"]


class BoardCreate(BaseModel):
    icon: BoardIcon = "auto"
    code: str = Field(min_length=1, max_length=60)
    name: str = Field(min_length=1, max_length=120)
    type: BoardType = BoardType.FREE
    description: str | None = None
    read_role: Role = Role.MEMBER
    write_role: Role = Role.MEMBER
    allow_comment: bool = True
    allow_attachment: bool = True
    allow_secret: bool = False
    notify_on_post: bool = False
    page_size: int = Field(20, ge=5, le=100)
    sort_order: int = 0


class BoardUpdate(PatchModel):
    icon: BoardIcon | None = None
    non_nullable: ClassVar[set[str]] = {
        "icon",
        "write_role",
        "read_role",
        "allow_comment",
        "allow_attachment",
        "type",
        "notify_on_post",
        "is_active",
        "name",
        "page_size",
        "sort_order",
        "allow_secret",
    }

    name: str | None = Field(None, max_length=120)
    type: BoardType | None = None
    description: str | None = None
    read_role: Role | None = None
    write_role: Role | None = None
    allow_comment: bool | None = None
    allow_attachment: bool | None = None
    allow_secret: bool | None = None
    notify_on_post: bool | None = None
    page_size: int | None = Field(None, ge=5, le=100)
    sort_order: int | None = None
    is_active: bool | None = None


class BoardOut(ORMModel):
    icon: str = "auto"
    id: uuid.UUID
    code: str
    name: str
    type: BoardType
    description: str | None = None
    read_role: Role
    write_role: Role
    allow_comment: bool
    allow_attachment: bool
    allow_secret: bool
    notify_on_post: bool
    page_size: int
    sort_order: int
    is_active: bool
    created_at: datetime


class PostCreate(BaseModel):
    title: str = Field(min_length=1, max_length=250)
    content: str = ""
    is_pinned: bool = False
    is_secret: bool = False
    status: PostStatus = PostStatus.PUBLISHED


class PostUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {
        "is_pinned",
        "is_secret",
        "content",
        "status",
        "title",
    }

    title: str | None = Field(None, max_length=250)
    content: str | None = None
    is_pinned: bool | None = None
    is_secret: bool | None = None
    status: PostStatus | None = None


class PostListItem(ORMModel):
    """List rows omit content so a 500-post page stays small."""

    id: uuid.UUID
    board_id: uuid.UUID
    title: str
    author_id: uuid.UUID | None = None
    status: PostStatus
    is_pinned: bool
    is_secret: bool
    view_count: int
    attachment_count: int = 0
    author: UserBrief | None = None
    comment_count: int
    created_at: datetime
    updated_at: datetime


class CommentCreate(BaseModel):
    content: str = Field(min_length=1)
    parent_id: uuid.UUID | None = None
    is_secret: bool = False


class CommentUpdate(PatchModel):
    non_nullable: ClassVar[set[str]] = {"content"}

    content: str = Field(min_length=1)


class CommentOut(ORMModel):
    id: uuid.UUID
    post_id: uuid.UUID
    parent_id: uuid.UUID | None = None
    author_id: uuid.UUID | None = None
    author: UserBrief | None = None
    content: str
    is_secret: bool
    created_at: datetime
    updated_at: datetime


class PostDetail(PostListItem):
    content: str
    author: UserBrief | None = None
    comments: list[CommentOut] = Field(default_factory=list)
