"""Preserve code/dependencies/unit before update; optional verified SQLite rollback."""

import argparse
import json
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import cloud_backup
from backup_bundle import config, database_path, extract_bundle
from sqlite_backup import restore


def prepare(root, unit):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
    metadata = json.loads(
        (root / "backups/.drive-private/last_cloud_backup.json").read_text()
    )
    folder = root / "backups/revisions" / stamp
    folder.mkdir(parents=True, mode=0o700)
    with tempfile.TemporaryDirectory(dir=root / "backups/.drive-private") as temp:
        work = Path(temp)
        payload = work / "payload"
        payload.mkdir()
        shutil.copytree(
            root / "backend",
            payload / "backend",
            symlinks=True,
            ignore=shutil.ignore_patterns(
                "__pycache__",
                "*.pyc",
                ".env",
                "*.db",
                "*.db-wal",
                "*.db-shm",
                "storage",
            ),
        )
        if unit.exists():
            shutil.copy2(unit, payload / "service.unit")
        source = work / metadata["name"]
        cloud_backup.download_archive(root, metadata, source)
        source.rename(payload / "data.zip")
        (payload / "snapshot.json").write_text(
            json.dumps({"archive": "data.zip", "unit": str(unit)})
        )
        archive = work / ("update_" + stamp + ".zip")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
            for path in payload.rglob("*"):
                z.write(path, path.relative_to(payload).as_posix())
        cloud = cloud_backup.upload_archive(root, archive)
        (folder / "snapshot.json").write_text(
            json.dumps({"cloud": cloud, "unit": str(unit)})
        )
    # Only the cloud pointer remains on disk; code/data archives are temporary.
    return folder


def verify_running(port):
    for _ in range(30):
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz", timeout=2
            ) as response:
                if response.status == 200:
                    return
        except OSError:
            pass
        time.sleep(1)
    subprocess.run(["systemctl", "stop", "ddeck"], check=False)
    raise RuntimeError("Rollback server failed health check; service stopped")


def recover(root, folder):
    if not folder.resolve().is_relative_to((root / "backups/revisions").resolve()):
        raise ValueError("Snapshot outside backup directory")
    metadata = json.loads((folder / "snapshot.json").read_text())
    if "cloud" in metadata:
        with tempfile.TemporaryDirectory(dir=root / "backups/.drive-private") as temp:
            work = Path(temp)
            archive = work / metadata["cloud"]["name"]
            cloud_backup.download_archive(root, metadata["cloud"], archive)
            extract_bundle(archive, work / "payload")
            return _recover_payload(root, work / "payload", local=False)
    return _recover_payload(root, folder, local=True)


def _recover_payload(root, folder, *, local):
    metadata = json.loads((folder / "snapshot.json").read_text())
    archive_root = root / "backups" if local else folder
    archive = archive_root / metadata["archive"]
    if archive.parent.resolve() != archive_root.resolve():
        raise ValueError("Invalid archive")
    values = config(folder if local else root)
    destination = database_path(root, values["DATABASE_URL"])
    if destination is None:
        raise RuntimeError(
            "Automatic rollback supports SQLite only; restore PostgreSQL manually"
        )
    storage = Path(values.get("STORAGE_DIR", str(root / "storage")))
    if not storage.is_absolute():
        storage = root / "backend" / storage
    with tempfile.TemporaryDirectory(dir=root / "backups") as temporary:
        extracted = Path(temporary)
        extract_bundle(archive, extracted)
        if not (extracted / "ddeck.db").is_file():
            raise RuntimeError("SQLite snapshot missing")
        subprocess.run(["systemctl", "stop", "ddeck"], check=True)
        staged = root / "backend.rollback"
        if staged.exists():
            raise RuntimeError("Previous rollback staging exists; inspect it first")
        shutil.copytree(folder / "backend", staged, symlinks=True)
        if not local:
            shutil.copy2(root / "backend/.env", staged / ".env")
        failed = extracted / "failed-backend"
        (root / "backend").rename(failed)
        staged.rename(root / "backend")
        destination.parent.mkdir(parents=True, exist_ok=True)
        restore(extracted / "ddeck.db", destination)
        shutil.copytree(extracted / "storage", storage, dirs_exist_ok=True)
        if (folder / "service.unit").exists():
            shutil.copy2(folder / "service.unit", Path(metadata["unit"]))
        subprocess.run(
            [
                "chown",
                "-R",
                "ddeck:ddeck",
                str(root / "backend"),
                str(storage),
            ],
            check=True,
        )
        subprocess.run(["chown", "ddeck:ddeck", str(destination)], check=True)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "start", "ddeck"], check=True)
        unit_text = (
            (folder / "service.unit").read_text()
            if (folder / "service.unit").exists()
            else ""
        )
        match = re.search(r"--port\s+(\d+)", unit_text)
        verify_running(int(match.group(1)) if match else 8000)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "recover"])
    parser.add_argument("--root", type=Path, default=Path("/opt/ddeck"))
    parser.add_argument(
        "--unit", type=Path, default=Path("/etc/systemd/system/ddeck.service")
    )
    parser.add_argument("--snapshot", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        print(prepare(args.root, args.unit))
    elif args.snapshot:
        recover(args.root, args.snapshot)
    else:
        parser.error("--snapshot is required")
