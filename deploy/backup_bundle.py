"""Portable, verified backup bundles. No shell commands or user-provided executable strings."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import zipfile
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit


def config(root):
    values = {}
    for line in (root / "backend/.env").read_text(encoding="utf-8-sig").splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.strip().startswith("#"):
            values[key.strip()] = value.strip().strip("\"'")
    return {**values, **os.environ}


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    temporary.chmod(0o600)
    if hasattr(os, "chown") and os.geteuid() == 0:
        owner = path.parent.stat()
        os.chown(temporary, owner.st_uid, owner.st_gid)
    temporary.replace(path)


def database_path(root, url):
    if not url.startswith("sqlite"):
        return None
    path = unquote(url.split(":///", 1)[1].split("?", 1)[0])
    return Path(path) if Path(path).is_absolute() else root / "backend" / path


def storage_path(root, values):
    path = Path(values.get("STORAGE_DIR", str(root / "storage")))
    if not path.is_absolute():
        path = root / "backend" / path
    path = path.resolve()
    if path == Path(path.anchor) or (root / "backend").resolve().is_relative_to(path):
        raise ValueError(
            "Storage cannot contain application code or the filesystem root"
        )
    return path


def restore_postgres(root, dump):
    url = config(root)["DATABASE_URL"]
    if not url.startswith("postgresql") or not dump.is_file():
        raise ValueError("PostgreSQL dump and target configuration are required")
    environment = pg_environment(url)
    subprocess.run(
        ["pg_restore", "--list", str(dump)],
        env=environment,
        check=True,
        capture_output=True,
        timeout=60,
    )
    subprocess.run(
        [
            "pg_restore",
            "--exit-on-error",
            "--single-transaction",
            "--clean",
            "--if-exists",
            "--no-owner",
            "--no-privileges",
            "--dbname",
            environment["PGDATABASE"],
            str(dump),
        ],
        env=environment,
        check=True,
        capture_output=True,
        timeout=3600,
    )


def pg_environment(url):
    parsed = urlsplit(url.replace("postgresql+psycopg:", "postgresql:"))
    environment = {**os.environ}
    if os.name == "nt" and not shutil.which("pg_dump"):
        candidates = list(
            (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "PostgreSQL"
            ).glob("*/bin/pg_dump.exe")
        )
        candidates.sort(
            key=lambda path: (
                int(path.parent.parent.name) if path.parent.parent.name.isdigit() else 0
            ),
            reverse=True,
        )
        if candidates:
            environment["PATH"] = (
                str(candidates[0].parent) + os.pathsep + environment.get("PATH", "")
            )
    return {
        **environment,
        "PGHOST": parsed.hostname or "localhost",
        "PGPORT": str(parsed.port or 5432),
        "PGUSER": unquote(parsed.username or ""),
        "PGPASSWORD": unquote(parsed.password or ""),
        "PGDATABASE": unquote(parsed.path.lstrip("/")),
    }


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def extract_bundle(archive, target):
    """Reject absolute paths, traversal and symlinks before extraction on both OSes."""
    target = target.resolve()

    def safe(name):
        if (
            "\\" in name
            or ":" in name
            or not (target / name).resolve().is_relative_to(target)
        ):
            raise ValueError("Unsafe archive path")

    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                safe(entry.filename)
                if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError("Archive symlink refused")
            z.extractall(target)
    else:
        with tarfile.open(archive) as t:
            for entry in t.getmembers():
                safe(entry.name)
                if not entry.isfile() and not entry.isdir():
                    raise ValueError("Archive links/devices refused")
            t.extractall(target, filter="data")
    manifest = target / "manifest.json"
    if manifest.exists():
        for name, expected in json.loads(manifest.read_text())["sha256"].items():
            safe(name)
            if digest(target / name) != expected:
                raise ValueError("Backup checksum mismatch: " + name)
    if (target / "ddeck.db").exists():
        with closing(sqlite3.connect(target / "ddeck.db")) as db:
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("Backup database integrity failure")


def backup(root, *, keep=7, data_only=False, temporary=False, work_dir=None):
    root = Path(root).resolve()
    values = config(root)
    base = root / "backups"
    base.mkdir(parents=True, exist_ok=True)
    folder = (
        (Path(work_dir) if work_dir is not None else base / ".drive-private/uploads")
        if temporary
        else base
    )
    folder.mkdir(parents=True, exist_ok=True)
    folder.chmod(0o700)
    lock = base / ".backup.lock"
    # Exclusive lock file is also understood by the app's manual request path.
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise RuntimeError(
            "백업이 이미 실행 중입니다. 중단된 작업이면 프로세스 확인 후 .backup.lock을 제거하세요."
        ) from None
    os.close(descriptor)
    state = {"started_at": datetime.now(timezone.utc).isoformat(), "status": "running"}
    temporary_zip = None
    archive = None
    try:
        atomic_json(folder / "status.json", state)
        url = values.get("DATABASE_URL", "sqlite:///./ddeck.db")
        db_path = database_path(root, url)
        storage = storage_path(root, values)
        needed = (
            sum(p.stat().st_size for p in storage.rglob("*") if p.is_file())
            if storage.exists()
            else 0
        )
        needed += db_path.stat().st_size if db_path else 0
        if shutil.disk_usage(folder).free < needed * 3 + 128 * 1024 * 1024:
            raise RuntimeError("백업을 위한 디스크 여유 공간이 부족합니다.")
        with tempfile.TemporaryDirectory(prefix=".bundle-", dir=folder) as staging_dir:
            work = Path(staging_dir)
            if db_path:
                if not db_path.is_file():
                    raise FileNotFoundError("SQLite source missing")
                with (
                    closing(
                        sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True)
                    ) as source,
                    closing(sqlite3.connect(work / "ddeck.db")) as target,
                ):
                    source.backup(target)
                    if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                        raise ValueError("Database integrity failure")
                    revision = (
                        target.execute(
                            "SELECT version_num FROM alembic_version"
                        ).fetchall()
                        if target.execute(
                            "SELECT 1 FROM sqlite_master WHERE name='alembic_version'"
                        ).fetchone()
                        else []
                    )
            else:
                subprocess.run(
                    ["pg_dump", "-Fc", "-f", str(work / "db.dump")],
                    env=pg_environment(url),
                    check=True,
                    timeout=3600,
                    capture_output=True,
                )
                subprocess.run(
                    ["pg_restore", "--list", str(work / "db.dump")],
                    env=pg_environment(url),
                    check=True,
                    timeout=60,
                    capture_output=True,
                )
                revision_result = subprocess.run(
                    ["psql", "-At", "-c", "SELECT version_num FROM alembic_version"],
                    env=pg_environment(url),
                    check=True,
                    timeout=60,
                    capture_output=True,
                    text=True,
                )
                revision = [
                    [line] for line in revision_result.stdout.splitlines() if line
                ]

            if storage.exists():
                shutil.copytree(storage, work / "storage")
            else:
                (work / "storage").mkdir()
            if not data_only:
                shutil.copy2(root / "backend/.env", work / ".env")
                for source in [
                    Path("/etc/systemd/system/ddeck.service"),
                    Path("/etc/cron.d/ddeck-backup"),
                    Path("/etc/systemd/system/ddeck.service.d/https.conf"),
                    Path("/etc/nginx/conf.d/ddeck.conf"),
                    root / "deploy/windows-service.ps1",
                ]:
                    if source.is_file():
                        (work / "operations").mkdir(exist_ok=True)
                        shutil.copy2(source, work / "operations" / source.name)
                if os.name == "nt":
                    for name in ("d-ddeck DB Server", "d-ddeck 백업"):
                        result = subprocess.run(
                            [
                                "powershell.exe",
                                "-NoProfile",
                                "-Command",
                                f"[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; Get-ScheduledTask -TaskName '{name}' -ErrorAction SilentlyContinue | Export-ScheduledTask",
                            ],
                            check=True,
                            capture_output=True,
                            text=True,
                            encoding="utf-8",
                            timeout=30,
                        )
                        (work / "operations").mkdir(exist_ok=True)
                        (
                            work
                            / "operations"
                            / (
                                "server-task.xml"
                                if name == "d-ddeck DB Server"
                                else "backup-task.xml"
                            )
                        ).write_text(
                            result.stdout.replace(
                                'encoding="UTF-16"', 'encoding="UTF-8"'
                            ).replace('encoding="utf-16"', 'encoding="utf-8"'),
                            encoding="utf-8",
                        )
            manifest = {
                "format": 1,
                "database": "sqlite" if db_path else "postgresql",
                "revision": revision,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "sha256": {
                    p.relative_to(work).as_posix(): digest(p)
                    for p in work.rglob("*")
                    if p.is_file()
                },
            }
            atomic_json(work / "manifest.json", manifest)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
            prefix = "drive_" if data_only else "ddeck_"
            archive = folder / f"{prefix}{stamp}.zip"
            temporary_zip = archive.with_suffix(".zip.tmp")
            with zipfile.ZipFile(temporary_zip, "w", zipfile.ZIP_DEFLATED) as z:
                for path in work.rglob("*"):
                    z.write(path, path.relative_to(work).as_posix())
            with tempfile.TemporaryDirectory(dir=folder) as check:
                extract_bundle(temporary_zip, Path(check))
            temporary_zip.chmod(0o600)
            temporary_zip.replace(archive)
        for old in sorted(folder.glob(f"{prefix}*.zip"), reverse=True)[max(1, keep) :]:
            old.unlink()
        state.update(
            status="ok",
            finished_at=datetime.now(timezone.utc).isoformat(),
            archive=archive.name,
            sha256=digest(archive),
        )
        (folder / "LAST_FAILED").unlink(missing_ok=True)
        atomic_json(folder / "last_success.json", state)
        return archive
    except Exception:
        if temporary and archive is not None:
            archive.unlink(missing_ok=True)
        state.update(
            status="failed", finished_at=datetime.now(timezone.utc).isoformat()
        )
        (folder / "LAST_FAILED").write_text(state["finished_at"])
        raise
    finally:
        if temporary_zip is not None:
            temporary_zip.unlink(missing_ok=True)
        try:
            atomic_json(folder / "status.json", state)
        finally:
            lock.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--extract", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--database-path", action="store_true")
    parser.add_argument("--storage-path", action="store_true")
    parser.add_argument("--restore-postgres", type=Path)
    # Legacy flag accepted; routine backups always use Google.
    parser.add_argument("--local-only", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--data-only", action="store_true")
    parser.add_argument("--temporary", action="store_true")
    parser.add_argument("--keep", type=int, default=7)
    args = parser.parse_args()
    if args.storage_path:
        print(storage_path(args.root, config(args.root)))
        return
    if args.restore_postgres:
        restore_postgres(args.root, args.restore_postgres)
        return
    if args.database_path:
        print(database_path(args.root, config(args.root)["DATABASE_URL"]) or "")
        return
    if args.extract:
        if not args.destination:
            parser.error("--destination is required")
        extract_bundle(args.extract, args.destination)
    elif not args.temporary:
        from cloud_backup import create

        print(create(args.root.resolve())["name"])
    else:
        print(
            backup(
                args.root,
                keep=args.keep,
                data_only=args.data_only,
                temporary=args.temporary,
            )
        )


if __name__ == "__main__":
    main()
