"""Admin-only Drive backup; credentials live outside application DB/attachments.

A private SQLite transaction serializes state across server workers. A renewable
lease prevents concurrent jobs and lets interrupted jobs recover after restart.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import secrets
import sqlite3
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from zoneinfo import ZoneInfo

import httpx

from app.core.config import settings
from app.core.errors import AppError
from app.services import rclone_backup, shared_drive
from app.services.operations import backup_root

SCOPE = "https://www.googleapis.com/auth/drive.file"
API = "https://www.googleapis.com/drive/v3"
TZ = ZoneInfo("Asia/Seoul")
LEASE = 10800  # backup subprocess is bounded to two hours, upload to < one hour

# 백업 후 전원 끄기. 루트 도우미(deploy/power_helper.py)가 요청 파일을 읽어 끈다.
POWER_PATH_UNIT = Path("/etc/systemd/system/ddeck-power.path")
POWER_HELPER = Path("/usr/local/sbin/ddeck-power-off")
# 예약 시각보다 이만큼 넘게 늦게 시작한 백업(부팅 직후 밀린 백업 등)은 끄지 않는다.
# 그렇지 않으면 켜짐 → 밀린 백업 → 다시 꺼짐이 반복된다.
POWER_ON_TIME = timedelta(minutes=15)
# 다시 켜질 때까지 최소 간격. 도우미도 5분 미만은 거부한다.
POWER_MIN_OFF = timedelta(minutes=10)
# 유예가 끝난 지 이보다 오래된 요청(그사이 정전·재부팅)은 버린다.
POWER_STALE = timedelta(minutes=10)

log = logging.getLogger(__name__)


@contextmanager
def state():
    folder = backup_root() / "backups" / ".drive-private"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder.chmod(0o700)
    path = folder / "state.db"
    # Create with restrictive permissions before SQLite opens it.
    import os

    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    path.chmod(0o600)
    db = sqlite3.connect(path, timeout=30)
    try:
        db.execute(
            "CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, data TEXT NOT NULL)"
        )
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT data FROM state WHERE id=1").fetchone()
        data = json.loads(row[0]) if row else {}
        yield data
        db.execute("INSERT OR REPLACE INTO state VALUES (1, ?)", (json.dumps(data),))
        db.commit()
    finally:
        db.close()


def busy(s):
    return s.get("lease_until", 0) > time.time()


def require_idle(s):
    if busy(s):
        raise AppError("BACKUP_RUNNING", "백업 중에는 계정을 변경할 수 없습니다.", 409)


def next_run(s, now=None):
    now = now or datetime.now(TZ)
    at = now.replace(hour=s.get("hour", 3), minute=0, second=0, microsecond=0)
    if at <= now:
        at += timedelta(days=1)
    return at.isoformat()


def connected(s):
    return bool(
        s.get("rclone_target") or s.get("service_account") or s.get("refresh_token")
    )


def configure_rclone(target):
    target = target.strip()
    with state() as s:
        require_idle(s)
        before = dict(s)
    name = rclone_backup.validate(target)
    with state() as s:
        require_idle(s)
        if dict(s) != before:
            raise AppError(
                "CONNECTION_CHANGED",
                "연결 설정이 변경되었습니다. 다시 시도하세요.",
                409,
            )
        for key in (
            "service_account",
            "refresh_token",
            "pending",
            "exchanging",
            "drive_id",
            "folder_id",
        ):
            s.pop(key, None)
        s.update(
            rclone_target=target,
            email=name,
            folder_name=target,
            requested=False,
            last_error=None,
        )
        s["next_run_at"] = next_run(s) if s.get("enabled") else None
    return status()


def configure_shared_drive(raw_key, target):
    target = shared_drive.folder_id(target)
    with state() as s:
        require_idle(s)
        before = {
            k: s.get(k)
            for k in ("service_account", "refresh_token", "folder_id", "client_id")
        }
        info = shared_drive.parse_key(raw_key) if raw_key else s.get("service_account")
        if not info:
            raise AppError(
                "SERVICE_ACCOUNT_REQUIRED",
                "서비스 계정 JSON 키 파일을 선택하세요.",
                422,
            )
    try:
        folder = shared_drive.validate_connection(info, target)
    except httpx.HTTPError:
        raise AppError(
            "SHARED_DRIVE_CONNECTION",
            "Google Drive 연결을 확인하고 다시 시도하세요.",
            502,
        ) from None
    with state() as s:
        require_idle(s)
        if any(s.get(k) != v for k, v in before.items()):
            raise AppError(
                "CONNECTION_CHANGED",
                "연결 설정이 변경되었습니다. 다시 시도하세요.",
                409,
            )
        for key in ("rclone_target", "refresh_token", "pending", "exchanging"):
            s.pop(key, None)
        s.update(
            service_account=info,
            email=info["client_email"],
            folder_id=target,
            folder_name=folder["name"],
            drive_id=folder["driveId"],
            requested=False,
            last_error=None,
        )
        s["next_run_at"] = next_run(s) if s.get("enabled") else None
    return status()


def status():
    with state() as s:
        return {
            "configured": bool(
                s.get("client_id") and s.get("client_secret") and s.get("redirect_uri")
            ),
            "client_id": s.get("client_id", ""),
            "redirect_uri": s.get("redirect_uri", ""),
            "connected": connected(s),
            "connection_type": "rclone"
            if s.get("rclone_target")
            else ("shared_drive" if s.get("service_account") else "oauth"),
            "rclone_target": s.get("rclone_target", ""),
            "retention_count": 30 if s.get("rclone_target") else None,
            "folder_name": s.get("folder_name"),
            "drive_id": s.get("drive_id"),
            "account": s.get("email"),
            "enabled": s.get("enabled", False),
            "hour": s.get("hour", 3),
            "timezone": "Asia/Seoul",
            "scheduler_enabled": settings.SCHEDULER_ENABLED,
            "next_run_at": s.get("next_run_at") if s.get("enabled") else None,
            "running": busy(s),
            "requested": s.get("requested", False),
            "last_success_at": s.get("last_success_at"),
            "last_account": s.get("last_account"),
            "last_file_id": s.get("last_file_id"),
            "last_error": s.get("last_error"),
            "folder_id": s.get("folder_id"),
            "power": _power_status(s),
        }


def power_request():
    return backup_root() / "backups" / ".power" / "request"


def power_ready():
    """루트 도우미가 설치되어 이 서버의 요청 파일을 지켜보고 있는지."""
    if sys.platform != "linux":
        return False
    try:
        unit = POWER_PATH_UNIT.read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    expected = "PathExists=" + str(power_request()).replace("%", "%%")
    return expected in unit and POWER_HELPER.is_file()


def next_wake(s, after):
    """[after] 에서 최소 간격을 둔 뒤 처음 오는 '다시 켤 시각'."""
    at = after.replace(
        hour=s.get("power_wake_hour", 7),
        minute=s.get("power_wake_minute", 0),
        second=0,
        microsecond=0,
    )
    while at < after + POWER_MIN_OFF:
        at += timedelta(days=1)
    return at


def _power_status(s):
    return {
        "enabled": s.get("power_enabled", False),
        "grace_minutes": s.get("power_grace_minutes", 5),
        "wake_hour": s.get("power_wake_hour", 7),
        "wake_minute": s.get("power_wake_minute", 0),
        "ready": power_ready(),
        "pending": s.get("power_pending"),
        "last_requested_at": s.get("power_requested_at"),
        "last_wake_at": s.get("power_wake_at"),
        "note": s.get("power_note"),
    }


def power_settings(enabled, grace_minutes, wake_hour, wake_minute):
    if enabled and not power_ready():
        raise AppError(
            "POWER_HELPER_MISSING",
            "서버 PC에 전원 제어 도우미가 설치되지 않았습니다. "
            "서버 PC에서 sudo python3 deploy/power_helper.py --install 을 실행하세요.",
            409,
        )
    with state() as s:
        s.update(
            power_enabled=enabled,
            power_grace_minutes=grace_minutes,
            power_wake_hour=wake_hour,
            power_wake_minute=wake_minute,
        )
        pending = s.get("power_pending")
        if not enabled:
            s["power_pending"] = None
        elif pending:
            # 이미 카운트다운 중이면 끄는 시각은 두고 켜는 시각만 새 설정을 따른다.
            shutdown = datetime.fromisoformat(pending["shutdown_at"])
            pending["wake_at"] = next_wake(s, shutdown).isoformat()
    return status()


def power_cancel():
    with state() as s:
        if s.get("power_pending"):
            s["power_pending"] = None
            s["power_note"] = "관리자가 이번 전원 끄기를 취소했습니다."
    return status()


def _power_tick(now):
    """유예가 끝난 전원 끄기 요청을 루트 도우미에게 넘긴다."""
    with state() as s:
        pending = s.get("power_pending")
        if not pending or busy(s):
            return
        shutdown = datetime.fromisoformat(pending["shutdown_at"])
        if shutdown > now:
            return
        s["power_pending"] = None
        if not s.get("power_enabled"):
            return
        if now - shutdown > POWER_STALE:
            s["power_note"] = "예정 시각이 지나(서버 재시작 등) 이번 전원 끄기를 건너뛰었습니다."
            return
        if not power_ready():
            s["power_note"] = "전원 제어 도우미가 없어 전원을 끄지 않았습니다."
            return
        wake = next_wake(s, now)
        request = power_request()
        try:
            request.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            staged = request.with_name(".request.tmp")
            staged.write_text(str(int(wake.timestamp())), encoding="ascii")
            os.replace(staged, request)
        except OSError:
            log.exception("power-off request failed")
            s["power_note"] = "전원 끄기 요청을 기록하지 못했습니다. 서버 저장 공간과 권한을 확인하세요."
            return
        s.update(
            power_requested_at=now.isoformat(),
            power_wake_at=wake.isoformat(),
            power_note=None,
        )
    log.info("power-off requested, wake at %s", wake.isoformat())


def _notify_power(shutdown, wake):
    """관리자에게 곧 꺼진다고 알린다. 알림 실패는 백업 결과와 무관하다."""
    try:
        from sqlalchemy import select

        from app.core.database import SessionLocal
        from app.models.enums import NotificationType, Role, UserStatus
        from app.models.user import User
        from app.services import notifications

        with SessionLocal() as db:
            admins = db.scalars(
                select(User.id).where(
                    User.role.in_([Role.ADMIN, Role.SUPERADMIN]),
                    User.status == UserStatus.APPROVED,
                )
            ).all()
            if not admins:
                return
            notifications.notify(
                db,
                user_ids=admins,
                type=NotificationType.SYSTEM,
                title="[서버] 백업 완료 후 서버 PC 전원이 꺼집니다",
                body=f"{shutdown:%H:%M}에 꺼지고 {wake:%m/%d %H:%M}에 다시 켜집니다. "
                "취소하려면 관리 > Google 공유 드라이브 백업에서 취소하세요.",
                payload={"route": "/admin/drive-backup"},
            )
            db.commit()
    except Exception:  # notification is best effort
        log.exception("power-off notification failed")


def configure(client_id, client_secret, redirect_uri):
    uri = urlsplit(redirect_uri)
    if (
        (
            uri.scheme != "https"
            and not (
                uri.scheme == "http" and uri.hostname in {"localhost", "127.0.0.1"}
            )
        )
        or uri.query
        or uri.fragment
        or uri.username
        or not uri.hostname
        or not uri.path.endswith("/admin/drive-backup/callback")
    ):
        raise AppError(
            "INVALID_REDIRECT",
            "콜백 주소는 HTTPS 서버 주소와 /api/v1/admin/drive-backup/callback 경로를 사용하세요. 로컬 테스트만 HTTP localhost를 허용합니다.",
            422,
        )
    with state() as s:
        require_idle(s)
        if connected(s):
            raise AppError(
                "DRIVE_CONNECTED",
                "OAuth 앱 설정을 변경하려면 먼저 계정 연결을 해제하세요.",
                409,
            )
        secret = client_secret or s.get("client_secret")
        if not secret:
            raise AppError(
                "SECRET_REQUIRED", "클라이언트 보안 비밀번호를 입력하세요.", 422
            )
        s.update(client_id=client_id, client_secret=secret, redirect_uri=redirect_uri)
        s.pop("pending", None)
        s.pop("exchanging", None)
    return status()


def authorization_url():
    with state() as s:
        require_idle(s)
        if not s.get("client_secret"):
            raise AppError(
                "OAUTH_NOT_CONFIGURED", "먼저 Google OAuth 앱을 설정하세요.", 409
            )
        nonce, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
        s.pop("exchanging", None)
        s["pending"] = {
            "state": nonce,
            "verifier": verifier,
            "expires": time.time() + 600,
        }
        challenge = (
            base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
            .rstrip(b"=")
            .decode()
        )
        return {
            "url": "https://accounts.google.com/o/oauth2/v2/auth?"
            + urlencode(
                {
                    "client_id": s["client_id"],
                    "redirect_uri": s["redirect_uri"],
                    "response_type": "code",
                    "scope": SCOPE,
                    "access_type": "offline",
                    "prompt": "consent select_account",
                    "state": nonce,
                    "code_challenge": challenge,
                    "code_challenge_method": "S256",
                }
            )
        }


def checked(response):
    if response.status_code >= 400:
        # Do not leak request URLs, authorization codes or provider response bodies.
        raise AppError(
            "DRIVE_ERROR",
            f"Google Drive 요청에 실패했습니다 (HTTP {response.status_code}). 계정 권한·저장 용량을 확인하고 필요하면 다시 연결하세요.",
            502,
        )
    return response.json() if response.content else {}


def callback(nonce, code, denied=False):
    with state() as s:
        p = s.get("pending", {})
        if (
            not nonce
            or not secrets.compare_digest(nonce, p.get("state", ""))
            or p.get("expires", 0) < time.time()
        ):
            raise AppError(
                "INVALID_OAUTH_STATE",
                "연결 요청이 만료되었거나 유효하지 않습니다. 앱에서 다시 연결하세요.",
                400,
            )
        require_idle(s)
        s.pop("pending")  # consume even denied/failed authorization
        s["exchanging"] = nonce
        config = dict(s)
    if denied or not code:
        raise AppError(
            "OAUTH_CANCELLED",
            "Google 계정 연결이 취소되었습니다. 기존 연결은 유지됩니다.",
            400,
        )
    with httpx.Client(timeout=30) as client:
        token = checked(
            client.post(
                "https://oauth2.googleapis.com/token",
                data={
                    "code": code,
                    "client_id": config["client_id"],
                    "client_secret": config["client_secret"],
                    "redirect_uri": config["redirect_uri"],
                    "grant_type": "authorization_code",
                    "code_verifier": p["verifier"],
                },
            )
        )
        if (
            not token.get("refresh_token")
            or SCOPE not in token.get("scope", "").split()
        ):
            raise AppError(
                "DRIVE_CONSENT_REQUIRED",
                "Drive 백업 권한을 허용하고 다시 연결하세요.",
                400,
            )
        user = checked(
            client.get(
                API + "/about",
                params={"fields": "user(emailAddress,permissionId)"},
                headers={"Authorization": "Bearer " + token["access_token"]},
            )
        )["user"]
    with state() as s:
        require_idle(s)
        if (
            s.get("exchanging") != nonce
            or s.get("pending")
            or any(
                s.get(k) != config.get(k)
                for k in ("client_id", "client_secret", "redirect_uri", "refresh_token")
            )
        ):
            raise AppError(
                "OAUTH_CHANGED", "연결 설정이 변경되었습니다. 다시 시도하세요.", 409
            )
        s.pop("exchanging", None)
        for key in ("rclone_target", "service_account", "folder_name", "drive_id"):
            s.pop(key, None)
        s.update(
            refresh_token=token["refresh_token"],
            email=user["emailAddress"],
            folder_id=None,
            last_error=None,
            requested=False,
        )
        # Old files remain in the old account. Never transfer or delete them.
        s["next_run_at"] = next_run(s)
    return "Google Drive 연결이 완료되었습니다. 앱으로 돌아가 새로고침하세요."


def disconnect():
    with state() as s:
        require_idle(s)
        for key in (
            "rclone_target",
            "refresh_token",
            "service_account",
            "email",
            "folder_id",
            "folder_name",
            "drive_id",
            "pending",
            "exchanging",
        ):
            s.pop(key, None)
        s.update(enabled=False, requested=False, next_run_at=None)
    return status()


def schedule(enabled, hour):
    if enabled and not settings.SCHEDULER_ENABLED:
        raise AppError(
            "SCHEDULER_DISABLED", "서버 백업 실행기가 비활성화되어 있습니다.", 503
        )
    with state() as s:
        if enabled and not connected(s):
            raise AppError("DRIVE_NOT_CONNECTED", "Google 계정을 먼저 연결하세요.", 409)
        s.update(enabled=enabled, hour=hour)
        s["next_run_at"] = next_run(s) if enabled else None
    return status()


def request_backup():
    if not settings.SCHEDULER_ENABLED:
        raise AppError(
            "SCHEDULER_DISABLED", "서버 백업 실행기가 비활성화되어 있습니다.", 503
        )
    with state() as s:
        require_idle(s)
        if not connected(s):
            raise AppError("DRIVE_NOT_CONNECTED", "Google 계정을 먼저 연결하세요.", 409)
        s["requested"] = True
    return status()


def upload(s, archive):
    if s.get("rclone_target"):
        return rclone_backup.upload(s["rclone_target"], archive)
    with httpx.Client(timeout=120) as client:
        if s.get("service_account"):
            client.headers["Authorization"] = "Bearer " + shared_drive.access_token(
                s["service_account"]
            )
        else:
            token = checked(
                client.post(
                    "https://oauth2.googleapis.com/token",
                    data={
                        "client_id": s["client_id"],
                        "client_secret": s["client_secret"],
                        "refresh_token": s["refresh_token"],
                        "grant_type": "refresh_token",
                    },
                )
            )
            client.headers["Authorization"] = "Bearer " + token["access_token"]
        folder = s.get("folder_id")
        if s.get("service_account"):
            if not folder:
                raise AppError(
                    "SHARED_DRIVE_FOLDER_REQUIRED",
                    "공유 드라이브 폴더를 설정하세요.",
                    409,
                )
            shared_drive.validate_folder(client, folder)
        if not folder:
            folder = checked(
                client.post(
                    API + "/files",
                    params={"fields": "id"},
                    json={
                        "name": "D.DDECK 자동 백업",
                        "mimeType": "application/vnd.google-apps.folder",
                    },
                )
            )["id"]
            with state() as current:
                current["folder_id"] = folder
        size = archive.stat().st_size
        response = client.post(
            "https://www.googleapis.com/upload/drive/v3/files",
            params={
                "uploadType": "resumable",
                "fields": "id,size,md5Checksum",
                "supportsAllDrives": "true",
            },
            headers={
                "X-Upload-Content-Type": "application/zip",
                "X-Upload-Content-Length": str(size),
            },
            json={"name": archive.name, "parents": [folder]},
        )
        checked(response)
        uri = response.headers["Location"]
        parsed = urlsplit(uri)
        if parsed.scheme != "https" or parsed.hostname != "www.googleapis.com":
            raise RuntimeError("Unexpected upload location")
        checksum = hashlib.md5(usedforsecurity=False)
        deadline = time.monotonic() + 3000
        with archive.open("rb") as stream:
            offset = 0
            while offset < size:
                if time.monotonic() > deadline:
                    raise TimeoutError("Upload deadline")
                chunk = stream.read(8 * 1024 * 1024)
                checksum.update(chunk)
                response = client.put(
                    uri,
                    content=chunk,
                    headers={
                        "Content-Type": "application/zip",
                        "Content-Range": f"bytes {offset}-{offset + len(chunk) - 1}/{size}",
                    },
                )
                offset += len(chunk)
                if offset < size:
                    if (
                        response.status_code != 308
                        or response.headers.get("Range") != f"bytes=0-{offset - 1}"
                    ):
                        raise RuntimeError("Incomplete upload")
                else:
                    result = checked(response)
        if int(result["size"]) != size or result["md5Checksum"] != checksum.hexdigest():
            raise RuntimeError("Backup upload checksum mismatch")
        return result["id"]


def tick():
    now = datetime.now(TZ)
    _power_tick(now)
    with state() as s:
        if busy(s) or not connected(s):
            return
        due = (
            s.get("enabled")
            and s.get("next_run_at")
            and datetime.fromisoformat(s["next_run_at"]) <= now
        )
        if not s.get("requested") and not due:
            return
        # 전원 끄기는 예약 시각에 제때 시작한 자동 백업에만 이어진다.
        on_time = bool(due) and not s.get("requested") and (
            now - datetime.fromisoformat(s["next_run_at"]) <= POWER_ON_TIME
        )
        # The existing local backup tool has its own cross-process lock.
        if (backup_root() / "backups" / ".backup.lock").exists():
            return
        job = secrets.token_hex(16)
        s.update(
            lease_until=time.time() + LEASE, job=job, requested=False, last_error=None
        )
        config = dict(s)
    archive = None
    try:
        root = backup_root()
        result = subprocess.run(
            [
                sys.executable,
                str(root / "deploy/backup_bundle.py"),
                "--root",
                str(root),
                "--local-only",
                "--data-only",
                "--temporary",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=7200,
        )
        output = (root / "backups/.drive-private/uploads").resolve()
        candidate = (output / result.stdout.strip().splitlines()[-1]).resolve()
        if candidate.parent != output or not candidate.is_file():
            raise RuntimeError("Invalid backup archive")
        archive = candidate
        file_id = upload(config, archive)
        power_off = None
        with state() as s:
            if s.get("job") == job:
                s.update(
                    last_success_at=datetime.now(TZ).isoformat(),
                    last_file_id=file_id,
                    last_account=config["email"],
                    last_error=None,
                )
                if s.get("power_enabled") and on_time:
                    shutdown = datetime.now(TZ) + timedelta(
                        minutes=s.get("power_grace_minutes", 5)
                    )
                    power_off = (shutdown, next_wake(s, shutdown))
                    s["power_pending"] = {
                        "shutdown_at": power_off[0].isoformat(),
                        "wake_at": power_off[1].isoformat(),
                    }
                    s["power_note"] = None
                elif s.get("power_enabled"):
                    s["power_note"] = (
                        "예약 시각에 실행된 자동 백업이 아니어서(수동·지연 실행) "
                        "전원을 끄지 않았습니다."
                    )
        if power_off:
            _notify_power(*power_off)
    except (
        AppError,
        httpx.HTTPError,
        OSError,
        ValueError,
        KeyError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as exc:
        with state() as s:
            if s.get("job") == job:
                s["last_error"] = (
                    exc.message
                    if isinstance(exc, AppError)
                    else "백업 또는 Drive 업로드에 실패했습니다. 서버 저장 공간, 네트워크, 계정 권한을 확인하고 즉시 백업으로 재시도하세요."
                )
    finally:
        try:
            if archive is not None:
                archive.unlink(missing_ok=True)
        finally:
            with state() as s:
                if s.get("job") == job:
                    s["lease_until"] = 0
                    s["next_run_at"] = next_run(s) if s.get("enabled") else None
