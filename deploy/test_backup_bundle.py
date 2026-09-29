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
        full = bundle.backup(self.root, remote="", keep=1)
        cloud = bundle.backup(self.root, remote="", keep=1, data_only=True)
        with zipfile.ZipFile(cloud) as z:
            self.assertNotIn(".env", z.namelist())
            self.assertFalse(any(n.startswith("operations/") for n in z.namelist()))
            self.assertIn("ddeck.db", z.namelist())
            self.assertIn("storage/item.txt", z.namelist())
        self.assertTrue(full.exists())
        bundle.extract_bundle(cloud, self.root / "cloud-restore")

    def test_roundtrip_and_retention(self):
        for _ in range(3):
            archive = bundle.backup(self.root, remote="", keep=2)
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

    def test_remote_failure_preserves_archives(self):
        bundle.backup(self.root, remote="", keep=1)
        with (
            patch.object(bundle.subprocess, "run", side_effect=RuntimeError("offline")),
            self.assertRaises(RuntimeError),
        ):
            bundle.backup(self.root, remote="backup:test", keep=1)
        self.assertEqual(len(list((self.root / "backups").glob("*.zip"))), 2)
        self.assertTrue((self.root / "backups/UPLOAD_FAILED").exists())
        self.assertFalse((self.root / "backups/.backup.lock").exists())

    def test_remote_config_and_verified_pruning(self):
        with (self.root / "backend/.env").open("a") as stream:
            stream.write("RCLONE_CONFIG=/safe/rclone.conf\n")
        from subprocess import CompletedProcess

        def run(command, **kwargs):
            self.assertEqual(kwargs["env"]["RCLONE_CONFIG"], "/safe/rclone.conf")
            return CompletedProcess(command, 0, stdout="[]")

        with patch.object(bundle.subprocess, "run", side_effect=run) as execute:
            bundle.backup(self.root, remote="backup:dedicated")
        self.assertEqual(
            [c.args[0][1] for c in execute.call_args_list],
            ["copyto", "check", "lsjson"],
        )
        self.assertTrue(
            json.loads((self.root / "backups/last_success.json").read_text())[
                "remote_verified"
            ]
        )

    def test_initial_status_failure_releases_lock(self):
        with (
            patch.object(bundle, "atomic_json", side_effect=OSError("disk failed")),
            self.assertRaises(OSError),
        ):
            bundle.backup(self.root, remote="")
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
            bundle.backup(self.root, remote="")
        self.assertEqual(
            json.loads((self.root / "backups/status.json").read_text())["status"],
            "failed",
        )
        self.assertFalse(list((self.root / "backups").glob("*.zip")))


if __name__ == "__main__":
    unittest.main()
