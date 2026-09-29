import importlib.util
import json
import sqlite3
import tempfile
import unittest
import zipfile
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "bundle", Path(__file__).with_name("backup_bundle.py")
)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "backend").mkdir()
        (self.root / "storage").mkdir()
        (self.root / "backend/.env").write_text(
            "DATABASE_URL=sqlite:///./ddeck.db\nSTORAGE_DIR=../storage\n"
        )
        with closing(sqlite3.connect(self.root / "backend/ddeck.db")) as db, db:
            db.execute("CREATE TABLE sample (value TEXT)")
            db.execute("INSERT INTO sample VALUES ('retained')")
        (self.root / "storage/item.txt").write_text("attachment")

    def test_cloud_data_only_excludes_secrets_and_keeps_full_backups(self):
        full = bundle.backup(self.root, keep=1)
        cloud = bundle.backup(self.root, keep=1, data_only=True)
        with zipfile.ZipFile(cloud) as z:
            self.assertNotIn(".env", z.namelist())
            self.assertFalse(any(n.startswith("operations/") for n in z.namelist()))
            self.assertIn("ddeck.db", z.namelist())
            self.assertIn("storage/item.txt", z.namelist())
        self.assertTrue(full.exists())
        bundle.extract_bundle(cloud, self.root / "cloud-restore")

    def test_roundtrip_and_retention(self):
        for _ in range(3):
            archive = bundle.backup(self.root, keep=2)
        self.assertEqual(len(list((self.root / "backups").glob("*.zip"))), 2)
        target = self.root / "restored"
        bundle.extract_bundle(archive, target)
        self.assertEqual((target / "storage/item.txt").read_text(), "attachment")
        with closing(sqlite3.connect(target / "ddeck.db")) as db:
            self.assertEqual(
                db.execute("SELECT value FROM sample").fetchone()[0], "retained"
            )
        self.assertTrue((target / ".env").exists())
        self.assertEqual(
            json.loads((self.root / "backups/status.json").read_text())["status"], "ok"
        )

    def test_legacy_remote_settings_do_not_upload(self):
        with (self.root / "backend/.env").open("a") as stream:
            stream.write(
                "RCLONE_REMOTE=legacy:backup\nRCLONE_CONFIG=/legacy/rclone.conf\n"
            )
        with patch.object(bundle.subprocess, "run") as execute:
            archive = bundle.backup(self.root, data_only=True)
        # Windows full bundles may inspect scheduled tasks; data-only bundles
        # do not invoke any executable, including the retired remote uploader.
        execute.assert_not_called()
        self.assertTrue(archive.exists())
        self.assertNotIn(
            "remote_verified",
            json.loads((self.root / "backups/last_success.json").read_text()),
        )

    def test_initial_status_failure_releases_lock(self):
        with (
            patch.object(bundle, "atomic_json", side_effect=OSError("disk failed")),
            self.assertRaises(OSError),
        ):
            bundle.backup(self.root)
        self.assertFalse((self.root / "backups/.backup.lock").exists())

    def test_traversal_rejected(self):
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("../escape", "bad")
        with self.assertRaises(ValueError):
            bundle.extract_bundle(archive, self.root / "out")
        self.assertFalse((self.root / "escape").exists())

    def test_checksum_rejected(self):
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("file", "corrupt")
            z.writestr("manifest.json", json.dumps({"sha256": {"file": "bad"}}))
        with self.assertRaises(ValueError):
            bundle.extract_bundle(archive, self.root / "out")

    def test_space_failure_records_status(self):
        with (
            patch.object(
                bundle.shutil,
                "disk_usage",
                return_value=type("Usage", (), {"free": 0})(),
            ),
            self.assertRaises(RuntimeError),
        ):
            bundle.backup(self.root)
        self.assertEqual(
            json.loads((self.root / "backups/status.json").read_text())["status"],
            "failed",
        )
        self.assertFalse(list((self.root / "backups").glob("*.zip")))


if __name__ == "__main__":
    unittest.main()
