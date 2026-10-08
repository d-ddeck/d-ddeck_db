"""Operator backups use the same verified Google destination as the application."""

import argparse
import atexit
import json
import os
import sys
import tempfile
from pathlib import Path

from backup_bundle import backup

_guarded = set()


def config_owner_guard(path):
    """root 로 돌린 rclone 이 토큰을 갱신하면 설정 파일을 root 소유로 새로 쓴다.

    그러면 서버 계정이 읽지 못해 이후 모든 Google 백업이 실패한다. 끝날 때 설정
    폴더 소유자로 되돌린다. root 가 아니면 할 일이 없다.
    """
    if os.name == "nt" or os.geteuid() != 0:
        return None
    path = Path(path)

    def restore():
        try:
            folder, current = os.stat(path.parent), os.stat(path)
            if (current.st_uid, current.st_gid) != (folder.st_uid, folder.st_gid):
                os.chown(path, folder.st_uid, folder.st_gid)
        except OSError:
            pass

    return restore


def service(root):
    sys.path.insert(0, str(root / "backend"))
    from dotenv import load_dotenv

    load_dotenv(root / "backend/.env", override=True)
    os.environ.update(DEBUG="false", BACKUP_ROOT=str(root))
    os.chdir(root / "backend")
    from app.services import drive_backup

    with drive_backup.state() as state:
        config_path = state.get("rclone_config")
    if not config_path and os.name != "nt":
        import pwd

        owner = (root / "backups/.drive-private/state.db").stat().st_uid
        candidate = Path(pwd.getpwuid(owner).pw_dir) / ".config/rclone/rclone.conf"
        if candidate.is_file():
            config_path = str(candidate)
    if config_path:
        os.environ["RCLONE_CONFIG"] = config_path
        restore = config_owner_guard(config_path)
        if restore and config_path not in _guarded:
            _guarded.add(config_path)
            restore()  # Heal a file left root-owned by an earlier operator run.
            atexit.register(restore)
    return drive_backup


def upload_archive(root, archive):
    d = service(root)
    from app.services import rclone_backup

    with d.state() as s:
        d.require_idle(s)
        config = dict(s)
    target = config.get("rclone_target")
    if not target:
        raise RuntimeError(
            "Google 백업 페이지에서 계정을 먼저 연결하세요. 작업을 중단합니다."
        )
    pattern = (
        rclone_backup.UPDATE_NAME
        if archive.name.startswith("update_")
        else rclone_backup.BACKUP_NAME
    )
    rclone_backup.upload(target, archive, pattern=pattern)
    return {"name": archive.name, "target": target}


def download_archive(root, metadata, destination):
    service(root)
    from app.services import rclone_backup as r

    name = metadata["name"]
    if not (r.UPDATE_NAME.fullmatch(name) or r.BACKUP_NAME.fullmatch(name)):
        raise ValueError("Invalid cloud snapshot name")
    target = metadata["target"]
    r.validate(target)
    r.run("copyto", target + "/" + name, str(destination), timeout=1800)
    r.run(
        "check",
        str(destination.parent),
        target,
        "--one-way",
        "--include",
        "/" + name,
        timeout=600,
    )


def create(root):
    # Validate the connection before creating any temporary data.
    d = service(root)
    with d.state() as s:
        d.require_idle(s)
        if not s.get("rclone_target"):
            raise RuntimeError("Google 백업 연결이 필요합니다.")
    private = root / "backups/.drive-private"
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Operator/root uploads must not create root-owned files in the app's
    # shared uploads directory; all operator staging lives in this context.
    with tempfile.TemporaryDirectory(prefix="operator-", dir=private) as temp:
        archive = backup(root, data_only=True, temporary=True, work_dir=Path(temp))
        try:
            metadata = upload_archive(root, archive)
            path = private / "last_cloud_backup.json"
            path.write_text(json.dumps(metadata), encoding="utf-8")
            path.chmod(0o600)
            return metadata
        finally:
            archive.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    args = parser.parse_args()
    try:
        result = create(args.root.resolve())
        print("Google 백업 검증 완료: " + result["name"])
    except Exception:  # noqa: BLE001 - never print credential-bearing transport errors
        print(
            "Google 백업 실패. 연결·권한·네트워크를 확인하세요. 작업을 중단합니다.",
            file=sys.stderr,
        )
        sys.exit(1)
