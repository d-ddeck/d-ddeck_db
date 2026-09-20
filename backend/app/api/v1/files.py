"""Attachment upload/download, shared by every module.

Files are stored on disk under STORAGE_DIR and only referenced from the DB, so
the database stays small enough to back up quickly.
"""
from __future__ import annotations

import re
import uuid
from pathlib import Path

from fastapi import APIRouter, File, Form, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import select

from app.core.config import settings as env
from app.core.deps import CurrentUser, DbSession
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import Attachment
from app.schemas.common import Message

router = APIRouter(prefix="/files", tags=["files"])

ALLOWED_ENTITIES = {"service_ticket", "asset", "post", "event", "user"}
_SAFE_NAME = re.compile(r"[^A-Za-z0-9가-힣._-]")
CHUNK = 1024 * 1024


@router.post("", status_code=status.HTTP_201_CREATED)
async def upload(
    db: DbSession,
    user: CurrentUser,
    entity_type: str = Form(...),
    entity_id: uuid.UUID = Form(...),
    file: UploadFile = File(...),
):
    if entity_type not in ALLOWED_ENTITIES:
        raise AppError("BAD_ENTITY", f"지원하지 않는 첨부 대상입니다: {entity_type}")

    safe = _SAFE_NAME.sub("_", Path(file.filename or "file").name)[:120]
    stored_name = f"{uuid.uuid4().hex}_{safe}"
    target_dir = env.storage_path / entity_type / str(entity_id)
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / stored_name

    # Streamed with a running size check so an oversized upload is cut off
    # instead of being buffered whole and rejected afterwards.
    limit = env.MAX_UPLOAD_MB * 1024 * 1024
    size = 0
    try:
        with target.open("wb") as fh:
            while chunk := await file.read(CHUNK):
                size += len(chunk)
                if size > limit:
                    raise AppError(
                        "FILE_TOO_LARGE",
                        f"최대 {env.MAX_UPLOAD_MB}MB까지 업로드할 수 있습니다.",
                        status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    )
                fh.write(chunk)
    except AppError:
        target.unlink(missing_ok=True)
        raise

    attachment = Attachment(
        entity_type=entity_type,
        entity_id=entity_id,
        original_name=safe,
        stored_path=str(target.relative_to(env.storage_path)).replace("\\", "/"),
        content_type=file.content_type,
        size_bytes=size,
        uploaded_by_id=user.id,
    )
    db.add(attachment)
    db.commit()
    db.refresh(attachment)
    return {
        "id": str(attachment.id),
        "original_name": attachment.original_name,
        "size_bytes": attachment.size_bytes,
        "content_type": attachment.content_type,
        "download_url": f"{env.API_V1_PREFIX}/files/{attachment.id}",
    }


@router.get("/by-entity/{entity_type}/{entity_id}")
def list_for_entity(
    entity_type: str, entity_id: uuid.UUID, db: DbSession, _: CurrentUser
):
    rows = db.scalars(
        select(Attachment)
        .where(
            Attachment.entity_type == entity_type,
            Attachment.entity_id == entity_id,
            Attachment.deleted_at.is_(None),
        )
        .order_by(Attachment.created_at)
    ).all()
    return [
        {
            "id": str(a.id),
            "original_name": a.original_name,
            "size_bytes": a.size_bytes,
            "content_type": a.content_type,
            "uploaded_by_id": str(a.uploaded_by_id) if a.uploaded_by_id else None,
            "created_at": a.created_at,
            "download_url": f"{env.API_V1_PREFIX}/files/{a.id}",
        }
        for a in rows
    ]


@router.get("/{attachment_id}")
def download(attachment_id: uuid.UUID, db: DbSession, _: CurrentUser):
    attachment = db.scalar(
        select(Attachment).where(
            Attachment.id == attachment_id, Attachment.deleted_at.is_(None)
        )
    )
    if attachment is None:
        raise AppError("NOT_FOUND", "파일을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)

    path = (env.storage_path / attachment.stored_path).resolve()
    # Guard against a stored_path that escapes the storage root.
    if not str(path).startswith(str(env.storage_path.resolve())) or not path.exists():
        raise AppError("FILE_MISSING", "파일이 존재하지 않습니다.", status.HTTP_404_NOT_FOUND)

    return FileResponse(
        path,
        filename=attachment.original_name,
        media_type=attachment.content_type or "application/octet-stream",
    )


@router.delete("/{attachment_id}", response_model=Message)
def delete(attachment_id: uuid.UUID, db: DbSession, user: CurrentUser) -> Message:
    attachment = db.scalar(
        select(Attachment).where(
            Attachment.id == attachment_id, Attachment.deleted_at.is_(None)
        )
    )
    if attachment is None:
        raise AppError("NOT_FOUND", "파일을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    if attachment.uploaded_by_id != user.id and user.role.value not in {
        "MANAGER",
        "ADMIN",
        "SUPERADMIN",
    }:
        raise AppError("FORBIDDEN", "삭제 권한이 없습니다.", status.HTTP_403_FORBIDDEN)

    # Soft delete only: the row keeps the audit trail, and a later cleanup job
    # can remove the bytes once nothing references them.
    attachment.deleted_at = now_utc()
    db.commit()
    return Message(message="삭제되었습니다.")
