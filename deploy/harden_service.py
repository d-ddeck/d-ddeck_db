"""Migrate a stopped legacy SQLite install out of code and restrict systemd writes."""

import argparse
import os
import re
from pathlib import Path

from backup_bundle import config, database_path, storage_path
from sqlite_backup import snapshot


def owned_write(path, text):
    owner = path.stat()
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.chmod(owner.st_mode & 0o777)
    if hasattr(os, "chown") and os.geteuid() == 0:
        os.chown(temporary, owner.st_uid, owner.st_gid)
    temporary.replace(path)


def harden(root, unit):
    values = config(root)
    db = database_path(root, values["DATABASE_URL"])
    if db is not None and db.resolve().is_relative_to((root / "backend").resolve()):
        destination = root / "data" / db.name
        if destination.exists():
            raise RuntimeError(
                "Destination database already exists; inspect before migration"
            )
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
        snapshot(db, destination)
        destination.chmod(0o600)
        if hasattr(os, "chown") and os.geteuid() == 0:
            owner = db.stat()
            os.chown(destination, owner.st_uid, owner.st_gid)
            os.chown(destination.parent, owner.st_uid, owner.st_gid)
        env = root / "backend/.env"
        text = env.read_text(encoding="utf-8-sig")
        text, changed = re.subn(
            r"^DATABASE_URL=.*$",
            lambda _: f"DATABASE_URL=sqlite+pysqlite:///{destination.as_posix()}",
            text,
            flags=re.MULTILINE,
        )
        if changed != 1:
            raise RuntimeError("A single DATABASE_URL entry is required")
        owned_write(env, text)
        db = destination
    content = unit.read_text()
    if "StartLimitIntervalSec=" not in content:
        content = content.replace(
            "[Unit]", "[Unit]\nStartLimitIntervalSec=300\nStartLimitBurst=10", 1
        )
    if "TimeoutStopSec=" not in content:
        content = content.replace("[Service]", "[Service]\nTimeoutStopSec=30", 1)
    if "Environment=PYTHONDONTWRITEBYTECODE=1" not in content:
        content = content.replace(
            "[Service]", "[Service]\nEnvironment=PYTHONDONTWRITEBYTECODE=1", 1
        )
    for option in ("--no-access-log", "--no-proxy-headers"):
        content = re.sub(
            r"^ExecStart=.*$",
            lambda match, flag=option: (
                match[0] if flag in match[0] else match[0] + " " + flag
            ),
            content,
            flags=re.MULTILINE,
        )
    paths = {storage_path(root, values), root / "backups", root / "data"}
    if db is not None:
        paths.add(db.resolve().parent)
    if any(re.search(r"[\s%]", str(path)) for path in paths):
        raise ValueError(
            "Service data paths must not contain whitespace or systemd specifiers"
        )
    line = "ReadWritePaths=" + " ".join(str(path) for path in sorted(paths))
    content, changed = re.subn(
        r"^ReadWritePaths=.*$", lambda _: line, content, flags=re.MULTILINE
    )
    if not changed:
        content = content.replace("[Service]", "[Service]\n" + line, 1)
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)
    owned_write(unit, content)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/opt/ddeck"))
    parser.add_argument(
        "--unit", type=Path, default=Path("/etc/systemd/system/ddeck.service")
    )
    args = parser.parse_args()
    harden(args.root, args.unit)
