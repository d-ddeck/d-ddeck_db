"""Operational status and a fixed-command background backup worker."""

import shutil
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
    from app.services.drive_backup import status

    data = status()
    finished = data.get("last_success_at")
    try:
        hours = (
            datetime.now(timezone.utc) - datetime.fromisoformat(finished)
        ).total_seconds() / 3600
    except (TypeError, ValueError):
        hours = None
    return {
        "state": "running" if data["running"] else "google_drive",
        "last_success_at": finished,
        "age_hours": hours,
        "overdue": bool(data["enabled"]) and (hours is None or hours >= 36),
        "failed": bool(data.get("last_error")),
        "requested": data["requested"],
        "connected": data["connected"],
    }


def health_details(db):
    revision = []
    if "alembic_version" in inspect(db.bind).get_table_names():
        revision = list(db.scalars(text("SELECT version_num FROM alembic_version")))
    return {
        "schema_revisions": revision,
        "disk_free_bytes": shutil.disk_usage(settings.storage_path).free,
        "backup": backup_status(),
    }
