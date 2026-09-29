"""Cross-process reader gate for requests/jobs and exclusive data restoration."""

import sqlite3
from contextlib import contextmanager
from functools import wraps

from starlette.responses import JSONResponse

from app.core.errors import AppError
from app.services.operations import backup_root


def folder():
    p = backup_root() / "backups/.drive-private"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def marker():
    return folder() / "restore-maintenance"


def initialize():
    path = folder() / "restore-gate.db"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE IF NOT EXISTS gate (id INTEGER)")
    path.chmod(0o600)


@contextmanager
def read():
    if marker().exists():
        raise AppError(
            "RESTORE_RUNNING", "서버 복구 중입니다. 잠시 후 다시 접속하세요.", 503
        )
    path = folder() / "restore-gate.db"
    if not path.exists():
        initialize()
    db = sqlite3.connect(path, timeout=0, check_same_thread=False)
    try:
        try:
            db.execute("BEGIN")
            db.execute("SELECT * FROM gate").fetchall()
            if marker().exists():
                raise sqlite3.OperationalError("maintenance")
        except sqlite3.OperationalError:
            raise AppError(
                "RESTORE_RUNNING", "서버 복구 중입니다. 잠시 후 다시 접속하세요.", 503
            ) from None
        yield
    finally:
        db.close()


def guarded(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        try:
            with read():
                return fn(*args, **kwargs)
        except AppError as exc:
            if exc.code != "RESTORE_RUNNING":
                raise

    return wrapped


class RestoreGateMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        # These capability-protected local endpoints never access the app DB.
        if scope["type"] != "http" or scope.get("path") in (
            "/api/v1/admin/drive-backup/restore/status",
            "/api/v1/admin/drive-backup/restore/download",
        ):
            return await self.app(scope, receive, send)
        guard = read()
        try:
            guard.__enter__()
        except AppError:
            return await JSONResponse(
                {
                    "error": {
                        "code": "RESTORE_RUNNING",
                        "message": "서버 복구 중입니다. 잠시 후 다시 접속하세요.",
                    }
                },
                status_code=503,
            )(scope, receive, send)
        try:
            await self.app(scope, receive, send)
        finally:
            guard.__exit__(None, None, None)
