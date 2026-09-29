"""Restore real temporary SQLite databases and attachments; never production data."""

import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

TEMP = tempfile.TemporaryDirectory()
ROOT = Path(TEMP.name)
os.environ.update(
    DEBUG="false",
    BACKUP_ROOT=str(ROOT),
    DATABASE_URL=f"sqlite:///{ROOT}/live.db",
    STORAGE_DIR=str(ROOT / "storage"),
    SCHEDULER_ENABLED="false",
)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core.errors import AppError
from app.services import drive_restore as d
from app.services import restore_gate as gate


def database(path, value, version="revision1"):
    with sqlite3.connect(path) as db:
        db.executescript(
            "CREATE TABLE alembic_version(version_num TEXT); CREATE TABLE items(value TEXT); CREATE TABLE refresh_tokens(id TEXT);"
        )
        db.execute("INSERT INTO alembic_version VALUES (?)", (version,))
        db.execute("INSERT INTO items VALUES (?)", (value,))
        db.execute("INSERT INTO refresh_tokens VALUES ('old-session')")


class RestoreTest(unittest.TestCase):
    def setUp(self):
        d.engine.dispose()
        for suffix in ("", "-wal", "-shm"):
            (ROOT / ("live.db" + suffix)).unlink(missing_ok=True)
        import shutil

        shutil.rmtree(ROOT / "storage", ignore_errors=True)
        (ROOT / "storage").mkdir()
        (ROOT / "storage/file.txt").write_text("current file")
        database(ROOT / "live.db", "current")
        gate.marker().unlink(missing_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT)
        self.stage = Path(self.temp.name)
        database(self.stage / "ddeck.db", "backup")
        (self.stage / "storage").mkdir()
        (self.stage / "storage/file.txt").write_text("backup file")
        self.ident = os.urandom(16).hex()
        with d.backup.state() as s:
            s.clear()
            s["refresh_token"] = "test-token"
            s["restore_job"] = {"id": self.ident, "stage": "validating"}

        self.cloud = {}

        def upload(config, archive):
            self.cloud[archive.name] = archive.read_bytes()
            return "verified-google-file"

        mocked = patch.object(d.backup, "upload", side_effect=upload)
        mocked.start()
        self.addCleanup(mocked.stop)

    def tearDown(self):
        self.temp.cleanup()

    def value(self):
        with sqlite3.connect(ROOT / "live.db") as db:
            return db.execute("SELECT value FROM items").fetchone()[0]

    def test_restore_and_safety_copy(self):
        d.apply(self.ident, self.stage)
        self.assertEqual(self.value(), "backup")
        self.assertEqual((ROOT / "storage/file.txt").read_text(), "backup file")
        self.assertFalse(gate.marker().exists())
        with sqlite3.connect(ROOT / "live.db") as db:
            self.assertEqual(
                db.execute("SELECT count(*) FROM refresh_tokens").fetchone()[0], 0
            )
        with d.backup.state() as state:
            name = state["restore_job"]["safety_backup"]
        safety = self.stage / "downloaded-safety.zip"
        safety.write_bytes(self.cloud[name])
        self.assertFalse((self.stage / name).exists())
        restored = self.stage / "safety"
        d.extract(safety, restored)
        with sqlite3.connect(restored / "ddeck.db") as db:
            self.assertEqual(
                db.execute("SELECT value FROM items").fetchone()[0], "current"
            )
        self.assertEqual((restored / "storage/file.txt").read_text(), "current file")

    def test_safety_upload_failure_never_changes_live_data(self):
        with (
            patch.object(
                d.backup, "upload", side_effect=AppError("CLOUD_FAIL", "offline", 502)
            ),
            self.assertRaises(AppError),
        ):
            d.apply(self.ident, self.stage)
        self.assertEqual(self.value(), "current")
        self.assertEqual((ROOT / "storage/file.txt").read_text(), "current file")
        self.assertFalse(gate.marker().exists())
        self.assertFalse(list(self.stage.glob("drive_*.zip")))

    def test_restore_keeps_existing_wal_connections_on_same_database(self):
        with sqlite3.connect(ROOT / "live.db") as other:
            other.execute("PRAGMA journal_mode=WAL")
            self.assertEqual(
                other.execute("SELECT value FROM items").fetchone()[0], "current"
            )
            d.apply(self.ident, self.stage)
            self.assertEqual(
                other.execute("SELECT value FROM items").fetchone()[0], "backup"
            )

    def test_failed_db_swap_rolls_back_files_and_db(self):
        real = d.copy_db

        def failing(source, target):
            if source == self.stage / "ddeck.db":
                raise OSError("simulated disk failure")
            return real(source, target)

        with (
            patch.object(d, "copy_db", side_effect=failing),
            self.assertRaises(OSError),
        ):
            d.apply(self.ident, self.stage)
        self.assertEqual(self.value(), "current")
        self.assertEqual((ROOT / "storage/file.txt").read_text(), "current file")
        self.assertFalse(gate.marker().exists())

    def test_failed_rollback_keeps_gate_closed(self):
        real = d.copy_db

        def failing(source, target):
            if target == ROOT / "live.db":
                raise OSError("disk failure")
            return real(source, target)

        with (
            patch.object(d, "copy_db", side_effect=failing),
            self.assertRaises(OSError),
        ):
            d.apply(self.ident, self.stage)
        self.assertTrue(gate.marker().exists())
        with self.assertRaises(AppError), gate.read():
            pass
        gate.marker().unlink()

    def test_version_mismatch_no_changes(self):
        with sqlite3.connect(self.stage / "ddeck.db") as db:
            db.execute("UPDATE alembic_version SET version_num='other'")
        with self.assertRaises(AppError):
            d.apply(self.ident, self.stage)
        self.assertEqual(self.value(), "current")
        self.assertFalse(gate.marker().exists())

    def test_gate_reader_blocks_exclusive_writer(self):
        gate.initialize()
        with (
            gate.read(),
            sqlite3.connect(gate.folder() / "restore-gate.db", timeout=0) as db,
            self.assertRaises(sqlite3.OperationalError),
        ):
            db.execute("BEGIN EXCLUSIVE")

    def test_traversal_and_missing_manifest_rejected(self):
        archive = self.stage / "bad.zip"
        for name in ("../outside", "/absolute", "a\\evil"):
            with zipfile.ZipFile(archive, "w") as z:
                z.writestr(name, "bad")
                z.writestr("manifest.json", "{}")
            with self.assertRaises(AppError):
                d.extract(archive, self.stage / "out")
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("ddeck.db", "bad")
        with self.assertRaises(AppError):
            d.extract(archive, self.stage / "out")

    def test_tampered_checksum_rejected(self):
        archive = self.stage / "bad.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("ddeck.db", "tampered")
            z.writestr("storage/", b"")
            z.writestr(
                "manifest.json",
                json.dumps(
                    {
                        "format": 1,
                        "database": "sqlite",
                        "sha256": {"ddeck.db": hashlib.sha256(b"original").hexdigest()},
                    }
                ),
            )
        with self.assertRaises(AppError):
            d.extract(archive, self.stage / "out")

    def test_download_verified_archive_without_modifying_server(self):
        name = "drive_20260929_000000_000000.zip"
        remote = self.stage / "remote.zip"
        d.safety_zip(
            remote, self.stage / "ddeck.db", self.stage / "storage", ["revision1"]
        )
        ticket = "test-ticket" * 4
        with d.backup.state() as s:
            s["restore_job"].update(
                name=name,
                owner_pid=os.getpid(),
                expires=time.time() + 3600,
                token_hash=hashlib.sha256(ticket.encode()).hexdigest(),
            )

        def command(*args, **kwargs):
            if args[0] == "lsjson":
                return json.dumps({"Size": remote.stat().st_size, "IsDir": False})
            if args[0] == "copyto":
                shutil.copyfile(remote, args[2])
            return ""

        with patch.object(d.rclone, "run", side_effect=command):
            d.work(self.ident, "gdrive:Backup", name, False)
        self.assertEqual(d.status(ticket)["stage"], "downloaded")
        path, returned = d.download(ticket)
        self.assertEqual(returned, name)
        self.assertEqual(d.digest(path), d.digest(remote))
        self.assertEqual(self.value(), "current")

    def test_failed_remote_verification_never_applies_restore(self):
        name = "drive_20260929_000000_000000.zip"
        remote = self.stage / "remote.zip"
        d.safety_zip(
            remote, self.stage / "ddeck.db", self.stage / "storage", ["revision1"]
        )

        def command(*args, **kwargs):
            if args[0] == "lsjson":
                return json.dumps({"Size": remote.stat().st_size, "IsDir": False})
            if args[0] == "copyto":
                shutil.copyfile(remote, args[2])
                return ""
            raise AppError("CHECK_FAILED", "checksum failed", 502)

        with (
            patch.object(d.rclone, "run", side_effect=command),
            patch.object(d, "apply") as apply,
        ):
            d.work(self.ident, "gdrive:Backup", name, True)
            apply.assert_not_called()
        self.assertEqual(self.value(), "current")
        with d.backup.state() as s:
            self.assertEqual(s["restore_job"]["stage"], "error")

    def test_ticket_and_unconfirmed_restore_rejected(self):
        with self.assertRaises(AppError):
            d.status("wrong-ticket")
        with self.assertRaises(AppError):
            d.start("drive_20260929_000000_000000.zip", True, "")


if __name__ == "__main__":
    unittest.main()
