"""Public, signed client installers. No business data or credentials are exposed."""

import json
import re
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse, JSONResponse

from app.core.client_updates import verify_manifest
from app.core.config import settings
from app.core.deps import AdminUser

router = APIRouter(prefix="/updates", tags=["client updates"])


def update_root() -> Path:
    return Path(settings.STORAGE_DIR) / "client-updates"


def load_release(path: Path):
    try:
        if path.stat().st_size > 65536:
            raise ValueError("Oversized manifest")
        envelope = json.loads(path.read_text())
        return envelope, verify_manifest(envelope)
    except FileNotFoundError:
        raise HTTPException(404, "No client update published") from None
    except (OSError, ValueError, KeyError, TypeError, InvalidSignature):
        raise HTTPException(503, "Client update metadata unavailable") from None


@router.get("/latest")
def latest():
    envelope, _ = load_release(update_root() / "latest.json")
    return JSONResponse(envelope, headers={"Cache-Control": "no-store"})


@router.get("/files/{release}/{filename}")
def installer(release: str, filename: str):
    if not re.fullmatch(r"\d+\.\d+\.\d+-\d+", release):
        raise HTTPException(404, "Unknown release")
    folder = update_root() / release
    _, metadata = load_release(folder / "update-manifest.json")
    if metadata["release"] != release:
        raise HTTPException(503, "Release mismatch")
    artifact = next(
        (a for a in metadata["artifacts"].values() if a["filename"] == filename), None
    )
    path = folder / filename
    if (
        artifact is None
        or not path.is_file()
        or path.is_symlink()
        or path.stat().st_size != artifact["size"]
    ):
        raise HTTPException(404, "Installer not available")
    return FileResponse(
        path,
        filename=filename,
        media_type="application/octet-stream",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@router.post("/sync")
def sync_now(_: AdminUser):
    """GitHub 최신 릴리즈를 지금 확인해 새 버전이면 게시한다(평소에는 30분마다 자동)."""
    import httpx

    from app.services.client_update_sync import sync

    try:
        return sync()
    except (httpx.HTTPError, OSError, ValueError, KeyError) as exc:
        raise HTTPException(502, f"업데이트 게시 실패: {type(exc).__name__}") from None
