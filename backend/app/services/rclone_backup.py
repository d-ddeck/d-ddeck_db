"""Server-owned Google user credentials; scoped, verified backup retention."""

import configparser
import json
import re
import shutil
import subprocess
import time
from pathlib import Path

from app.core.errors import AppError

BACKUP_NAME = re.compile(r"drive_\d{8}_\d{6}_\d{6}\.zip")
UPDATE_NAME = re.compile(r"update_\d{8}_\d{6}_\d{6}\.zip")
KEEP = 30


def run(*args, timeout=300):
    binary = shutil.which("rclone") or str(Path.home() / ".local/bin/rclone")
    try:
        return subprocess.run(
            [binary, *args, "--ask-password=false"],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        raise AppError(
            "RCLONE_FAILED",
            "서버 PC의 rclone 설치, Google 로그인, 공유 드라이브 접근·삭제 권한을 확인하세요.",
            502,
        ) from None


def validate(target):
    name, sep, folder = target.partition(":")
    if (
        not sep
        or not re.fullmatch(r"[A-Za-z0-9_-]+", name)
        or not folder
        or folder.startswith("/")
        or any(p in ("", ".", "..") for p in folder.split("/"))
        or any(c in folder for c in "\\:\r\n\x00")
    ):
        raise AppError(
            "RCLONE_TARGET",
            "gdrive:D.DDECK 백업 형식으로 전용 백업 폴더를 지정하세요.",
            422,
        )
    # Read redacted configuration in memory only. Never expose OAuth tokens.
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read_string(run("config", "redacted", name))
    if (
        not cfg.has_section(name)
        or cfg[name].get("type") != "drive"
        or not cfg[name].get("team_drive")
    ):
        raise AppError(
            "RCLONE_SHARED_DRIVE",
            "rclone에서 Google 공유 드라이브를 먼저 연결하세요.",
            422,
        )
    info = json.loads(run("lsjson", target, "--stat"))
    if not info.get("IsDir"):
        raise AppError("RCLONE_FOLDER", "백업 대상은 폴더여야 합니다.", 422)
    return name


def upload(target, archive, *, pattern=BACKUP_NAME):
    deadline = time.monotonic() + 3000

    def command(*args, timeout=300):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AppError(
                "RCLONE_TIMEOUT", "백업 업로드·정리 시간이 초과되었습니다.", 502
            )
        return run(*args, timeout=min(timeout, remaining))

    validate(target)
    if not pattern.fullmatch(archive.name):
        raise ValueError("Unexpected backup filename")
    destination = target + "/" + archive.name
    command("copyto", str(archive), destination, timeout=1800)
    command(
        "check",
        str(archive.parent),
        target,
        "--one-way",
        "--include",
        "/" + archive.name,
        timeout=600,
    )
    entries = json.loads(command("lsjson", target, "--files-only", "--max-depth", "1"))
    names = [
        e["Name"]
        for e in entries
        if not e.get("IsDir")
        and e.get("Path") == e.get("Name")
        and pattern.fullmatch(e.get("Name", ""))
    ]
    if archive.name not in names or len(names) != len(set(names)):
        raise AppError(
            "RCLONE_VERIFY",
            "백업 목록 검증 실패: 기존 파일을 삭제하지 않았습니다.",
            502,
        )
    # Ascending timestamp order, only immediate children matching our format.
    keep = {
        archive.name,
        *sorted((n for n in names if n != archive.name), reverse=True)[: KEEP - 1],
    }
    for name in sorted(set(names) - keep):
        command("deletefile", target + "/" + name, "--drive-use-trash=true")
    return destination
