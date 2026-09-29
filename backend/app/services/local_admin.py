"""Opt-in server-console login using a per-OS-user local credential.

No IP-only authentication. The browser cannot invoke this flow, and the secret
is never shipped in installers, ordinary DB backups or application settings.
"""

import hashlib
import json
import os
import secrets
import subprocess
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from app.core.errors import AppError
from app.core.security import now_utc
from app.models.enums import Role
from app.models.user import User
from app.services.operations import backup_root


def registry_path():
    return backup_root() / "backups" / ".local-admin" / "credential.json"


def private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    if os.name == "nt":
        who = subprocess.run(
            ["whoami"], check=True, capture_output=True, text=True
        ).stdout.strip()
        subprocess.run(
            [
                "icacls",
                str(path.parent),
                "/inheritance:r",
                "/grant:r",
                f"{who}:(OI)(CI)F",
                "*S-1-5-18:(OI)(CI)F",
            ],
            check=True,
            capture_output=True,
        )
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream)
    temporary.chmod(0o600)
    temporary.replace(path)


def enable(user, profile_dir, server_url):
    uri = urlsplit(server_url)
    if (
        uri.scheme not in {"http", "https"}
        or uri.hostname not in {"localhost", "127.0.0.1", "::1"}
        or uri.username
        or uri.password
        or uri.query
        or uri.fragment
        or uri.path not in {"", "/"}
    ):
        raise ValueError("A loopback server URL is required")
    if not user.can_login or user.role not in {Role.ADMIN, Role.SUPERADMIN}:
        raise ValueError("An active administrator is required")
    secret = secrets.token_urlsafe(48)
    private_write(
        registry_path(),
        {
            "user_id": str(user.id),
            "secret_hash": hashlib.sha256(secret.encode()).hexdigest(),
            "password_stamp": hashlib.sha256(user.password_hash.encode()).hexdigest(),
        },
    )
    private_write(
        Path(profile_dir) / ".ddeck" / "local-admin-login.json",
        {
            "server_url": server_url.rstrip("/"),
            "secret": secret,
        },
    )


def authenticate(db, request, secret):
    denied = AppError(
        "LOCAL_ADMIN_DENIED", "서버 PC 자동 로그인 설정을 확인하세요.", 401
    )
    if (
        not request.client
        or request.client.host not in {"127.0.0.1", "::1"}
        or any(
            key.lower() in {"origin", "forwarded", "x-real-ip"}
            or key.lower().startswith("x-forwarded-")
            for key in request.headers
        )
    ):
        raise denied
    try:
        data = json.loads(registry_path().read_text(encoding="utf-8"))
        if not secrets.compare_digest(
            data["secret_hash"], hashlib.sha256(secret.encode()).hexdigest()
        ):
            raise denied
        user = db.get(User, uuid.UUID(data["user_id"]))
        if (
            user is None
            or user.deleted_at is not None
            or not user.can_login
            or user.role not in {Role.ADMIN, Role.SUPERADMIN}
        ):
            raise denied
        if not secrets.compare_digest(
            data["password_stamp"],
            hashlib.sha256(user.password_hash.encode()).hexdigest(),
        ):
            raise denied
        if user.locked_until and user.locked_until > now_utc():
            raise denied
        return user
    except (OSError, ValueError, KeyError, TypeError):
        raise denied from None
