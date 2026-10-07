"""Download and restore verified data-only backups, without changing live config."""

import csv
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import threading
import time
import zipfile
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

from app.core.config import settings
from app.core.database import engine
from app.core.errors import AppError
from app.services import drive_backup as backup
from app.services import rclone_backup as rclone
from app.services import restore_gate as gate

log = logging.getLogger(__name__)


def fail(message):
    return AppError("RESTORE_INVALID", message, 422)


def prune_cache():
    if gate.marker().exists():
        return
    with backup.state() as s:
        job = s.get("restore_job", {})
        active = (
            job.get("id")
            if job.get("stage") not in ("downloaded", "restored", "error")
            else None
        )
    cache = gate.folder() / "downloads"
    if cache.exists():
        for path in cache.iterdir():
            if (
                re.fullmatch(r"[a-f0-9]{32}", path.name)
                and path.name != active
                and path.is_dir()
                and not path.is_symlink()
                and path.stat().st_mtime < time.time() - 86400
            ):
                shutil.rmtree(path, ignore_errors=True)


def files():
    prune_cache()
    with backup.state() as s:
        target = s.get("rclone_target")
    if not target:
        raise fail("Google 계정을 먼저 연결하세요.")
    entries = json.loads(
        rclone.run("lsjson", target, "--files-only", "--max-depth", "1")
    )
    names = [
        e.get("Name")
        for e in entries
        if not e.get("IsDir") and rclone.BACKUP_NAME.fullmatch(e.get("Name", ""))
    ]
    if len(names) != len(set(names)):
        raise fail(
            "이름이 중복된 백업 파일이 있습니다. 공유 드라이브에서 중복 파일을 정리하세요."
        )
    return {
        "files": sorted(
            [
                {"name": e["Name"], "size": e["Size"], "modified": e.get("ModTime")}
                for e in entries
                if not e.get("IsDir")
                and e.get("Path") == e.get("Name")
                and rclone.BACKUP_NAME.fullmatch(e.get("Name", ""))
            ],
            key=lambda e: e["name"],
            reverse=True,
        ),
        "restore_supported": settings.is_sqlite,
    }


def update(ident, **values):
    with backup.state() as s:
        if s.get("restore_job", {}).get("id") == ident:
            s["restore_job"].update(values)


def owner_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    if pid == os.getpid():
        return True
    if os.name != "nt":
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True
    # Never use os.kill(pid, 0) on Windows: it can terminate a process.
    try:
        exe = (
            Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/tasklist.exe"
        )
        result = subprocess.run(
            [str(exe), "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=10,
            check=True,
        )
        return any(
            len(row) > 1 and row[1] == str(pid)
            for row in csv.reader(result.stdout.splitlines())
        )
    except (OSError, subprocess.SubprocessError):
        return True


def start(name, restore, confirmation):
    if not rclone.BACKUP_NAME.fullmatch(name):
        raise fail("프로그램에서 생성한 백업 ZIP을 선택하세요.")
    if restore and (not settings.is_sqlite or confirmation != name):
        raise fail(
            "복구는 SQLite 서버에서 지원하며 선택한 백업 파일명을 확인해야 합니다."
        )
    if gate.marker().exists():
        raise fail(
            "이전 복구가 중단되었습니다. 안전 백업으로 서버 복구를 먼저 완료하세요."
        )
    prune_cache()
    token = secrets.token_urlsafe(40)
    ident = secrets.token_hex(16)
    with backup.state() as s:
        backup.require_idle(s)
        old = s.get("restore_job", {})
        if old.get("stage") not in (
            None,
            "downloaded",
            "restored",
            "error",
        ) and owner_alive(old.get("owner_pid")):
            raise fail("다른 다운로드 또는 복구가 진행 중입니다.")
        target = s.get("rclone_target")
        if not target:
            raise fail("Google 계정을 먼저 연결하세요.")
        s["restore_job"] = {
            "id": ident,
            "owner_pid": os.getpid(),
            "token_hash": hashlib.sha256(token.encode()).hexdigest(),
            "name": name,
            "stage": "downloading",
            "expires": time.time() + 86400,
        }
    threading.Thread(
        target=work, args=(ident, target, name, restore), daemon=True
    ).start()
    return {"ticket": token, "stage": "downloading"}


def status(ticket):
    with backup.state() as s:
        j = dict(s.get("restore_job", {}))
    if j.get("expires", 0) < time.time() or not hmac.compare_digest(
        j.get("token_hash", ""), hashlib.sha256(ticket.encode()).hexdigest()
    ):
        raise AppError("RESTORE_TICKET", "작업 조회 권한이 없거나 만료되었습니다.", 403)
    if j.get("stage") not in ("downloaded", "restored", "error") and not owner_alive(
        j.get("owner_pid")
    ):
        update(
            j["id"],
            stage="error",
            error="서버 재시작으로 작업이 중단되었습니다.",
            maintenance=gate.marker().exists(),
        )
        j.update(
            stage="error",
            error="서버 재시작으로 작업이 중단되었습니다.",
            maintenance=gate.marker().exists(),
        )
    return {
        k: v for k, v in j.items() if k not in ("token_hash", "expires", "owner_pid")
    }


def download(ticket):
    j = status(ticket)
    if j["stage"] not in ("downloaded", "restored"):
        raise fail("다운로드가 아직 완료되지 않았습니다.")
    return gate.folder() / "downloads" / j["id"] / j["name"], j["name"]


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def extract(archive, destination):
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        names = [e.filename for e in entries]
        if len(names) != len(set(names)) or "manifest.json" not in names:
            raise fail("백업 manifest가 없거나 중복 파일이 있습니다.")
        total = sum(e.file_size for e in entries)
        if total > shutil.disk_usage(destination.parent).free // 3:
            raise fail("압축 해제와 복구를 위한 저장 공간이 부족합니다.")
        for e in entries:
            p = Path(e.filename)
            if (
                p.is_absolute()
                or ".." in p.parts
                or "\\" in e.filename
                or ":" in e.filename
                or (e.external_attr >> 16) & 0o170000 == 0o120000
            ):
                raise fail("안전하지 않은 백업 경로입니다.")
            if e.file_size > 16 * 1024 * 1024 and e.filename == "manifest.json":
                raise fail("잘못된 manifest입니다.")
        manifest = json.loads(z.read("manifest.json"))
        if manifest.get("format") != 1 or manifest.get("database") != "sqlite":
            raise fail("SQLite 백업 형식이 아닙니다.")
        hashes = manifest.get("sha256", {})
        if set(hashes) != {
            e.filename
            for e in entries
            if not e.is_dir() and e.filename != "manifest.json"
        }:
            raise fail("백업 파일 목록이 manifest와 다릅니다.")
        z.extractall(destination)
    for name, expected in hashes.items():
        if digest(destination / name) != expected:
            raise fail("백업 파일 체크섬이 일치하지 않습니다.")
    database = destination / "ddeck.db"
    if not database.is_file() or not (destination / "storage").is_dir():
        raise fail("DB 또는 첨부파일 저장소가 없습니다.")
    with closing(sqlite3.connect(database)) as db:
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise fail("DB 무결성 검사에 실패했습니다.")
    return manifest


def copy_db(source, target):
    with (
        closing(sqlite3.connect(f"file:{source.as_posix()}?mode=ro", uri=True)) as src,
        closing(sqlite3.connect(target)) as dst,
    ):
        src.backup(dst)


def revisions(path):
    with closing(sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)) as db:
        return sorted(
            row[0] for row in db.execute("SELECT version_num FROM alembic_version")
        )


def safety_zip(path, database, storage, revision):
    manifest = {
        "format": 1,
        "database": "sqlite",
        "revision": [[r] for r in revision],
        "sha256": {},
    }
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with (
        os.fdopen(fd, "wb") as output,
        zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z,
    ):
        z.write(database, "ddeck.db")
        manifest["sha256"]["ddeck.db"] = digest(database)
        z.writestr("storage/", b"")
        for p in storage.rglob("*"):
            if p.is_symlink():
                raise fail("첨부파일 저장소의 심볼릭 링크는 복구 전에 정리해야 합니다.")
            if p.is_file():
                name = "storage/" + p.relative_to(storage).as_posix()
                z.write(p, name)
                manifest["sha256"][name] = digest(p)
        z.writestr("manifest.json", json.dumps(manifest))
    with zipfile.ZipFile(path) as z:
        if z.testzip():
            raise fail("복구 전 안전 백업 검증에 실패했습니다.")


def apply(ident, staged):
    live = Path(engine.url.database).resolve()
    storage = settings.storage_path.resolve()
    if revisions(staged / "ddeck.db") != revisions(live):
        raise fail("현재 서버와 DB 버전이 다릅니다. 같은 버전의 백업을 선택하세요.")
    new_storage = storage.with_name(storage.name + ".restore-new-" + ident)
    old_storage = storage.with_name(storage.name + ".restore-old-" + ident)
    if storage == live.parent or live.is_relative_to(storage):
        raise fail("DB와 첨부파일 경로가 겹쳐 자동 복구할 수 없습니다.")
    size = sum(p.stat().st_size for p in (staged / "storage").rglob("*") if p.is_file())
    if shutil.disk_usage(storage.parent).free < size + 128 * 1024 * 1024:
        raise fail("첨부파일 복구 공간이 부족합니다.")
    shutil.copytree(staged / "storage", new_storage)
    gate.initialize()
    # The marker blocks new readers even while existing operations drain.
    fd = os.open(gate.marker(), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    lock = sqlite3.connect(gate.folder() / "restore-gate.db", timeout=120)
    swapped = False
    db_started = False
    safe_to_open = True
    previous_db = staged / "previous.db"
    try:
        lock.execute("BEGIN EXCLUSIVE")
        update(ident, stage="safety_backup")
        engine.dispose()
        required = (
            2
            * (
                live.stat().st_size
                + sum(p.stat().st_size for p in storage.rglob("*") if p.is_file())
            )
            + 128 * 1024 * 1024
        )
        if shutil.disk_usage(staged).free < required:
            raise fail(
                "현재 자료의 안전 백업을 만들 공간이 부족합니다. 기존 자료는 변경하지 않았습니다."
            )
        copy_db(live, previous_db)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
        safe = staged / ("drive_" + stamp + ".zip")
        safety_zip(safe, previous_db, storage, revisions(live))
        with backup.state() as s:
            config = dict(s)
        if not backup.connected(config):
            raise fail("복구 전 Google 안전 백업 연결이 필요합니다.")
        try:
            backup.upload(config, safe)
        finally:
            safe.unlink(missing_ok=True)
        update(
            ident,
            safety_backup=safe.name,
            safety_location="google_drive",
            stage="restoring",
        )
        # Restored historical sessions must not become valid again.
        with sqlite3.connect(staged / "ddeck.db") as db:
            db.execute("DELETE FROM refresh_tokens")
            db.commit()
        storage.rename(old_storage)
        swapped = True
        new_storage.rename(storage)
        db_started = True
        copy_db(staged / "ddeck.db", live)
        engine.dispose()
    except Exception:
        if swapped:
            try:
                if db_started:
                    copy_db(previous_db, live)
                if storage.exists():
                    shutil.rmtree(storage)
                old_storage.rename(storage)
                engine.dispose()
            except Exception:  # noqa: BLE001 - rollback failure must keep maintenance closed
                safe_to_open = False
        raise
    finally:
        lock.close()
        if safe_to_open:
            gate.marker().unlink(missing_ok=True)
        if new_storage.exists():
            shutil.rmtree(new_storage, ignore_errors=True)
    shutil.rmtree(old_storage, ignore_errors=True)


def work(ident, target, name, restore):
    folder = gate.folder() / "downloads" / ident
    folder.mkdir(parents=True, mode=0o700)
    archive = folder / name
    try:
        # Query the exact object before downloading; don't fill the server disk.
        info = json.loads(rclone.run("lsjson", target + "/" + name, "--stat"))
        size = info.get("Size", -1)
        if (
            info.get("IsDir")
            or size < 0
            or size * 3 + 128 * 1024 * 1024 > shutil.disk_usage(folder).free
        ):
            raise fail("백업 파일 또는 서버 저장 공간을 확인하세요.")
        rclone.run("copyto", target + "/" + name, str(archive), timeout=1800)
        archive.chmod(0o600)
        rclone.run(
            "check",
            str(folder),
            target,
            "--one-way",
            "--include",
            "/" + name,
            timeout=600,
        )
        if restore:
            update(ident, stage="validating")
            extract(archive, folder / "staged")
            apply(ident, folder / "staged")
        update(ident, stage="restored" if restore else "downloaded")
    except Exception as exc:  # noqa: BLE001 - worker reports all failures without exposing secrets
        if not isinstance(exc, AppError):
            log.error("Backup download/restore failed: %s: %s", type(exc).__name__, exc)
        update(
            ident,
            stage="error",
            error=exc.message
            if isinstance(exc, AppError)
            else "다운로드 또는 복구에 실패했습니다. 현재 자료 보존 상태와 서버 저장 공간을 확인하세요.",
            maintenance=gate.marker().exists(),
        )
    finally:
        if not gate.marker().exists():
            shutil.rmtree(folder / "staged", ignore_errors=True)
        storage = settings.storage_path.resolve()
        shutil.rmtree(
            storage.with_name(storage.name + ".restore-new-" + ident),
            ignore_errors=True,
        )
