"""Back up the configured SQLite DB before explicitly restarting ddeck."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path


class Progress:
    def __init__(self, stream=None):
        self.stream = stream or sys.stdout
        self.last = -1

    def __call__(self, status, remaining, total):
        percent = int(100 * (total - remaining) / total) if total else 100
        if percent == self.last or (
            not self.stream.isatty() and percent < self.last + 10 and percent != 100
        ):
            return
        self.last = percent
        filled = percent * 30 // 100
        end = "\n" if percent == 100 or not self.stream.isatty() else ""
        print(
            f"\rDB 복사 [{'#' * filled}{'-' * (30 - filled)}] {percent:3d}%",
            end=end,
            file=self.stream,
            flush=True,
        )


def backup(source: Path, directory: Path, env_file: Path, progress=None) -> Path:
    if not source.is_file():
        raise RuntimeError("DB 파일이 없습니다. 빈 DB는 생성하지 않습니다.")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = directory / datetime.now(timezone.utc).astimezone().strftime(
        "restart-%Y%m%d-%H%M%S-%f"
    )
    target.mkdir(mode=0o700)
    staged = target / "database.partial"
    try:
        with (
            closing(
                sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)
            ) as src,
            closing(sqlite3.connect(staged)) as dst,
        ):
            src.backup(dst, pages=128, progress=progress or Progress(), sleep=0.05)
            print("백업 무결성 검사 중...", flush=True)
            if dst.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise RuntimeError("백업 DB 무결성 검사 실패")
        staged.chmod(0o600)
        shutil.copyfile(env_file, target / "backend.env")
        (target / "backend.env").chmod(0o600)
        with staged.open("rb") as file:
            digest = hashlib.file_digest(file, "sha256").hexdigest()
        (target / "manifest.json").write_text(
            json.dumps(
                {
                    "source": str(source),
                    "sha256": digest,
                    "created_at": datetime.now().astimezone().isoformat(),
                },
                indent=2,
            )
        )
        staged.rename(target / "ddeck.db")
        return target
    except BaseException:
        # Never advertise an incomplete backup as usable. Preserve it for diagnosis.
        print(
            f"백업 실패: 서버를 재시작하지 않습니다. 미완료 폴더: {target}",
            file=sys.stderr,
        )
        raise


def backup_then_restart(make_backup, check_schema, restart):
    path = make_backup()
    print(f"백업 완료: {path}", flush=True)
    check_schema()
    restart()
    return path


def main():
    parser = argparse.ArgumentParser(
        description="DB 백업 성공 및 스키마 확인 후 ddeck 재시작 (SQLite)"
    )
    parser.add_argument(
        "--backup-only", action="store_true", help="백업만 실행, 서비스 변경 없음"
    )
    parser.add_argument(
        "--backup-dir",
        type=Path,
        default=Path.home() / ".local/share/ddeck-backups/restarts",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    backend = root / "backend"
    os.umask(0o077)
    os.chdir(backend)
    sys.path.insert(0, str(backend))
    from sqlalchemy.engine import make_url

    from app.core.config import get_settings

    url = make_url(get_settings().DATABASE_URL)
    if (
        not url.drivername.startswith("sqlite")
        or not url.database
        or url.database == ":memory:"
    ):
        raise RuntimeError(
            "이 명령은 파일 기반 SQLite 전용입니다. 서버는 변경하지 않았습니다."
        )
    working = subprocess.check_output(
        ["systemctl", "show", "ddeck", "--property=WorkingDirectory", "--value"],
        text=True,
    ).strip()
    if Path(working).resolve() != backend.resolve():
        raise RuntimeError("ddeck 서비스 경로와 실행 중인 스크립트 경로가 다릅니다.")
    args.backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.backup_dir / ".restart.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not args.backup_only:
            # Authenticate before spending time on backup; never ask for a password in chat.
            subprocess.run(["sudo", "-v"], check=True)
        make_backup = lambda: backup(
            Path(url.database).resolve(), args.backup_dir, backend / ".env"
        )
        if args.backup_only:
            print(f"백업 완료: {make_backup()}")
            return

        def check_schema():
            print("서버 DB 구조 확인 중...", flush=True)
            subprocess.run(
                [sys.executable, str(root / "deploy/check_service_schema.py")],
                check=True,
            )

        def restart():
            print("백업 검증 완료. 서버 재시작 중...", flush=True)
            subprocess.run(["sudo", "-n", "systemctl", "restart", "ddeck"], check=True)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    with urllib.request.urlopen(
                        "http://127.0.0.1:8000/healthz", timeout=2
                    ) as response:
                        health = json.load(response)
                    if (
                        health.get("status") == "ok"
                        and subprocess.run(
                            ["systemctl", "is-active", "--quiet", "ddeck"], check=False
                        ).returncode
                        == 0
                    ):
                        print(
                            f"서버 정상 실행: {health.get('version', '버전 미표시')}",
                            flush=True,
                        )
                        return
                except (OSError, ValueError):
                    pass
                time.sleep(1)
            raise RuntimeError(
                "재시작 후 정상 응답을 확인하지 못했습니다. journalctl -u ddeck -n 30 으로 확인하세요."
            )

        backup_then_restart(make_backup, check_schema, restart)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(
            "\n작업이 중단됐습니다. 서비스 상태는 systemctl status ddeck으로 확인하세요.",
            file=sys.stderr,
        )
        sys.exit(130)
    except (
        OSError,
        RuntimeError,
        ValueError,
        sqlite3.Error,
        subprocess.SubprocessError,
    ) as error:
        print(f"실패: {error}", file=sys.stderr)
        sys.exit(1)
