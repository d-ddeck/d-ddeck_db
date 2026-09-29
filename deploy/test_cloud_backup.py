"""Operator cloud backups never retain local ZIPs, including upload failures."""

import sqlite3
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import cloud_backup as cloud


class Service:
    @contextmanager
    def state(self):
        yield {"rclone_target": "test:Backup"}

    def require_idle(self, state):
        pass


class CloudTests(unittest.TestCase):
    def test_temporary_archive_removed_after_success_and_failure(self):
        for failing in (False, True):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "backend").mkdir()
                (root / "storage").mkdir()
                (root / "backend/.env").write_text(
                    "DATABASE_URL=sqlite:///./ddeck.db\nSTORAGE_DIR=../storage\n"
                )
                with sqlite3.connect(root / "backend/ddeck.db") as db:
                    db.execute("CREATE TABLE sample(value TEXT)")

                def upload(root, archive, failing=failing):
                    self.assertTrue(archive.is_file())
                    if failing:
                        raise RuntimeError("offline")
                    return {"name": archive.name, "target": "test:Backup"}

                with (
                    patch.object(cloud, "service", return_value=Service()),
                    patch.object(cloud, "upload_archive", side_effect=upload),
                ):
                    if failing:
                        with self.assertRaises(RuntimeError):
                            cloud.create(root)
                    else:
                        result = cloud.create(root)
                        self.assertTrue(result["name"].startswith("drive_"))
                self.assertFalse(list((root / "backups").rglob("*.zip")))
                self.assertFalse((root / "backups/.backup.lock").exists())


if __name__ == "__main__":
    unittest.main()
