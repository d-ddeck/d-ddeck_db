"""Operational status and a fixed-command background backup worker."""

import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import inspect, text

from app.core.config import BASE_DIR, settings


def backup_root():
    return (
        Path(settings.BACKUP_ROOT).resolve()
        if settings.BACKUP_ROOT
        else BASE_DIR.parent
    )


def backup_status():
    folder = backup_root() / "backups"

    def read(name):
        try:
            return json.loads((folder / name).read_text())
        except (OSError, ValueError):
            return {}

    latest = read("last_success.json")
    state = read("status.json")
    finished = latest.get("finished_at")
    try:
        hours = (
            datetime.now(timezone.utc) - datetime.fromisoformat(finished)
        ).total_seconds() / 3600
    except (TypeError, ValueError):
        hours = None
    return {
        "state": state.get("status", "never"),
        "last_success_at": finished,
        "age_hours": round(hours, 1) if hours is not None else None,
        "overdue": hours is None or hours >= 36,
        "remote_verified": latest.get("remote_verified", False),
        "failed": (folder / "LAST_FAILED").exists(),
        "requested": (folder / "request.json").exists(),
    }


def process_backup_request():
    folder = backup_root() / "backups"
    request = folder / "request.json"
    if not request.exists():
        return
    running = folder / "request.running"
    try:
        request.replace(running)
    except FileNotFoundError:
        return
    try:
        script = backup_root() / "deploy/backup_bundle.py"
        if not script.is_file():
            raise RuntimeError("Backup utility is not installed")
        subprocess.run(
            [sys.executable, str(script), "--root", str(backup_root())],
            check=True,
            timeout=7200,
            capture_output=True,
        )
    except Exception:
        (folder / "LAST_FAILED").write_text(datetime.now(timezone.utc).isoformat())
        raise
    finally:
        running.unlink(missing_ok=True)


def health_details(db):
    revision = []
    if "alembic_version" in inspect(db.bind).get_table_names():
        revision = list(db.scalars(text("SELECT version_num FROM alembic_version")))
    return {
        "schema_revisions": revision,
        "disk_free_bytes": shutil.disk_usage(settings.storage_path).free,
        "backup": backup_status(),
    }
