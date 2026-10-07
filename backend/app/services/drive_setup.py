"""Local administrator wizard for rclone's non-interactive configuration API.

Continuation states and credentials stay server-side. A fresh random remote is
used until the administrator explicitly selects a folder and applies it.
"""

import json
import os
import re
import secrets
import shutil
import subprocess
import threading
import time
from pathlib import Path

from app.core.errors import AppError
from app.services import drive_backup as backup
from app.services import rclone_backup as rclone

TIMEOUT = 600
AUTH_URL = re.compile(r"http://127\.0\.0\.1:\d+/auth\?state=[A-Za-z0-9_-]+")


def local_console(request):
    return bool(
        request.client
        and request.client.host in {"127.0.0.1", "::1"}
        and not any(
            h in request.headers
            for h in ("origin", "forwarded", "x-forwarded-for", "x-real-ip")
        )
    )


def require_console(request):
    if not local_console(request):
        raise AppError(
            "SERVER_PC_ONLY", "Google 계정 연결은 서버 PC 앱에서 진행하세요.", 403
        )


def current(s, ident):
    w = s.get("drive_setup", {})
    if w.get("id") != ident or w.get("expires", 0) < time.time():
        raise AppError(
            "SETUP_EXPIRED",
            "연결 시간이 만료되었습니다. Google 로그인을 다시 시작하세요.",
            409,
        )
    return w


def public(w):
    option = dict(w.get("option") or {})
    if option.get("IsPassword") or option.get("Name") == "client_secret":
        option["Default"] = ""
    return {
        "id": w["id"],
        "stage": w["stage"],
        "error": w.get("error"),
        "option": {
            k: option.get(k)
            for k in (
                "Name",
                "Help",
                "Default",
                "Examples",
                "Required",
                "IsPassword",
                "Exclusive",
                "Type",
            )
        },
        "folder": w.get("folder", ""),
        "auth_url": w.get("auth_url") if w["stage"] == "working" else None,
    }


def get(ident):
    with backup.state() as s:
        return public(current(s, ident))


def start():
    binary = shutil.which("rclone") or str(Path.home() / ".local/bin/rclone")
    if not Path(binary).is_file():
        raise AppError("RCLONE_MISSING", "서버에 rclone을 먼저 설치해야 합니다.", 503)
    config_path = rclone.run("config", "file").strip().splitlines()[-1]
    ident = secrets.token_hex(16)
    with backup.state() as s:
        backup.require_idle(s)
        previous = s.get("drive_setup", {})
        if (
            previous.get("stage") in ("working", "question", "ready", "saving")
            and previous.get("expires", 0) > time.time()
        ):
            return public(previous)
        s["drive_setup"] = {
            "id": ident,
            "remote": "ddeck_ui_" + ident,
            "config_path": config_path,
            "stage": "working",
            "expires": time.time() + 1800,
            "baseline": s.get("rclone_target"),
        }
    threading.Thread(target=work, args=(ident, None), daemon=True).start()
    return get(ident)


def answer(ident, value):
    with backup.state() as s:
        w = current(s, ident)
        if w["stage"] != "question":
            raise AppError(
                "SETUP_BUSY", "연결이 진행 중입니다. 잠시 기다려 주세요.", 409
            )
        opt = w["option"]
        choices = [str(e["Value"]) for e in opt.get("Examples") or []]
        if (opt.get("Required") and not value) or (
            opt.get("Exclusive") and choices and value not in choices
        ):
            raise AppError("SETUP_ANSWER", "선택 항목을 확인하세요.", 422)
        w.update(
            stage="working", error=None, auth_url=None, expires=time.time() + 1800
        )
    threading.Thread(target=work, args=(ident, value), daemon=True).start()
    return get(ident)


def command(ident, args):
    binary = shutil.which("rclone") or str(Path.home() / ".local/bin/rclone")
    args = list(args)
    environment = dict(os.environ)
    # rclone supports RCLONE_RESULT/STATE for these flags. Avoid exposing OAuth
    # client secrets or continuation data in the process command line.
    for flag, key in (("--result", "RCLONE_RESULT"), ("--state", "RCLONE_STATE")):
        environment.pop(key, None)
        if flag in args:
            index = args.index(flag)
            environment[key] = args[index + 1]
            del args[index : index + 2]
    proc = subprocess.Popen(
        [binary, *args, "--non-interactive", "--ask-password=false"],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = []
    readers = [
        threading.Thread(target=lambda: output.append(proc.stdout.read()), daemon=True),
        threading.Thread(target=publish_auth_url, args=(ident, proc.stderr), daemon=True),
    ]
    for reader in readers:
        reader.start()
    deadline = time.monotonic() + TIMEOUT
    try:
        while True:
            with backup.state() as s:
                if current(s, ident)["stage"] == "cancelled":
                    raise AppError("SETUP_CANCELLED", "연결을 취소했습니다.", 409)
            if time.monotonic() > deadline:
                raise AppError(
                    "SETUP_TIMEOUT",
                    "로그인 시간이 초과되었습니다. 다시 연결하세요.",
                    408,
                )
            try:
                proc.wait(timeout=1)
                break
            except subprocess.TimeoutExpired:
                continue
        for reader in readers:
            reader.join(timeout=3)
        if proc.returncode:
            raise AppError(
                "SETUP_FAILED",
                "Google 연결에 실패했습니다. 브라우저 인증, OAuth 앱 설정 및 공유 드라이브 권한을 확인하세요.",
                502,
            )
        return json.loads(output[0] if output else "")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def publish_auth_url(ident, stream):
    # A service account has no desktop session, so rclone cannot open the
    # browser itself. Its loopback login link is shown in the server PC app.
    for line in stream:
        match = AUTH_URL.search(line)
        if not match:
            continue
        with backup.state() as s:
            w = s.get("drive_setup", {})
            if w.get("id") == ident and w.get("stage") == "working":
                w["auth_url"] = match.group(0)


def work(ident, value):
    remote = "ddeck_ui_" + ident
    try:
        with backup.state() as s:
            w = current(s, ident)
            args = (
                ["config", "create", remote, "drive", "scope", "drive"]
                if value is None
                else [
                    "config",
                    "update",
                    remote,
                    "--continue",
                    "--state",
                    w["state"],
                    "--result",
                    value,
                ]
            )
        # The local browser and shared-drive branch are fixed; other questions
        # (OAuth client settings and drive selection) are presented in the UI.
        for _ in range(15):
            result = command(ident, args)
            opt = result.get("Option") or {}
            name = opt.get("Name")
            auto = {"config_is_local": "true", "config_change_team_drive": "true"}
            if name in auto and not result.get("Error"):
                args = [
                    "config",
                    "update",
                    remote,
                    "--continue",
                    "--state",
                    result["State"],
                    "--result",
                    auto[name],
                ]
                continue
            with backup.state() as s:
                w = current(s, ident)
                if w["stage"] == "cancelled":
                    return
                w.update(
                    state=result.get("State", ""),
                    option=opt,
                    auth_url=None,
                    stage="question" if result.get("State") else "ready",
                    error="입력값 또는 계정 권한을 확인하고 다시 선택하세요."
                    if result.get("Error")
                    else None,
                )
            return
        raise RuntimeError("Too many configuration steps")
    except (AppError, OSError, ValueError, KeyError, RuntimeError):
        with backup.state() as s:
            w = s.get("drive_setup", {})
            if w.get("id") == ident and w.get("stage") != "cancelled":
                w.update(
                    stage="error",
                    error="Google 연결을 완료하지 못했습니다. 인증 취소·시간 초과, OAuth 앱 설정 또는 공유 드라이브 권한을 확인하고 다시 시도하세요.",
                )
    finally:
        with backup.state() as s:
            w = s.get("drive_setup", {})
            cleanup = w.get("id") != ident or w.get("stage") in ("cancelled", "error")
            in_use = s.get("rclone_target", "").startswith(remote + ":")
        if cleanup and not in_use:
            try:
                rclone.run("config", "delete", remote)
            except AppError:
                pass


def cancel(ident):
    with backup.state() as s:
        w = current(s, ident)
        if w["stage"] in ("saved", "saving"):
            raise AppError("SETUP_SAVED", "저장 중이거나 이미 적용된 연결입니다.", 409)
        was_working = w["stage"] == "working"
        remote = w["remote"]
        w["stage"] = "cancelled"
    if not was_working:
        rclone.run("config", "delete", remote)
    return {"cancelled": True}


def folder_path(value):
    if value and (
        value.startswith("/")
        or any(p in ("", ".", "..") for p in value.split("/"))
        or any(c in value for c in "\\:\r\n\x00")
    ):
        raise AppError("SETUP_FOLDER", "올바른 폴더를 선택하세요.", 422)
    return value


def ready(ident):
    with backup.state() as s:
        w = current(s, ident)
        if w["stage"] != "ready":
            raise AppError(
                "SETUP_NOT_READY",
                "Google 로그인과 공유 드라이브 선택을 먼저 완료하세요.",
                409,
            )
        return dict(w)


def folders(ident, parent):
    w = ready(ident)
    parent = folder_path(parent)
    entries = json.loads(
        rclone.run(
            "lsjson", w["remote"] + ":" + parent, "--dirs-only", "--max-depth", "1"
        )
    )
    return {
        "folders": sorted(
            [
                e["Name"]
                for e in entries
                if e.get("IsDir")
                and e.get("Path") == e.get("Name")
                and re.fullmatch(r"[^/\\:\r\n\x00]+", e.get("Name", ""))
            ]
        )
    }


def finish(ident, folder, create=False):
    folder = folder_path(folder.strip())
    if not folder:
        raise AppError(
            "SETUP_FOLDER", "공유 드라이브 안의 전용 백업 폴더를 선택하세요.", 422
        )
    w = ready(ident)
    target = w["remote"] + ":" + folder
    with backup.state() as s:
        backup.require_idle(s)
        active = current(s, ident)
        if active["stage"] != "ready":
            raise AppError("SETUP_BUSY", "연결 저장이 이미 진행 중입니다.", 409)
        active["stage"] = "saving"
    try:
        if create:
            rclone.run("mkdir", target)
        rclone.validate(target)
        with backup.state() as s:
            backup.require_idle(s)
            active = current(s, ident)
            if s.get("rclone_target") != w.get("baseline"):
                raise AppError(
                    "CONNECTION_CHANGED",
                    "다른 관리자가 연결을 변경했습니다. 다시 시작하세요.",
                    409,
                )
            for key in (
                "refresh_token",
                "service_account",
                "pending",
                "exchanging",
                "drive_id",
                "folder_id",
            ):
                s.pop(key, None)
            s.update(
                rclone_target=target,
                rclone_config=w.get("config_path"),
                email="Google 계정",
                folder_name=folder,
                requested=False,
                last_error=None,
            )
            s["next_run_at"] = backup.next_run(s) if s.get("enabled") else None
            active.update(stage="saved", folder=folder)
        return backup.status()
    except Exception:
        with backup.state() as s:
            active = s.get("drive_setup", {})
            if active.get("id") == ident:
                active["stage"] = "ready"
        raise
