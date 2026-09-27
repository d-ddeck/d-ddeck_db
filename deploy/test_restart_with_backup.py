"""Verify live SQLite backup and fail-closed restart ordering."""

import io
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from restart_with_backup import Progress, backup, backup_then_restart


class RestartTests(unittest.TestCase):
    def test_wal_snapshot_and_settings_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            env = base / ".env"
            env.write_text("EXAMPLE=value\n")
            db = sqlite3.connect(base / "source.db")
            try:
                db.execute("pragma journal_mode=wal")
                db.execute("create table records (value text)")
                db.executemany(
                    "insert into records values (?)", [("가" * 1000,)] * 1000
                )
                db.commit()
                stream = io.StringIO()
                target = backup(
                    base / "source.db", base / "backups", env, Progress(stream)
                )
                with sqlite3.connect(target / "ddeck.db") as saved:
                    self.assertEqual(
                        saved.execute("select count(*) from records").fetchone()[0],
                        1000,
                    )
                    self.assertEqual(
                        saved.execute("pragma integrity_check").fetchone()[0], "ok"
                    )
                self.assertEqual((target / "backend.env").read_text(), env.read_text())
                self.assertEqual((target / "ddeck.db").stat().st_mode & 0o777, 0o600)
                self.assertIn("100%", stream.getvalue())
                self.assertFalse((target / "database.partial").exists())
            finally:
                db.close()

    def test_missing_database_never_created(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            with self.assertRaises(RuntimeError):
                backup(base / "missing.db", base / "out", base / ".env")
            self.assertFalse((base / "missing.db").exists())

    def test_backup_and_schema_failures_never_restart(self):
        for failed_stage in ("backup", "schema"):
            save = Mock(return_value=Path("/backup"))
            schema = Mock()
            restart = Mock()
            (save if failed_stage == "backup" else schema).side_effect = RuntimeError(
                "failure"
            )
            with self.assertRaises(RuntimeError):
                backup_then_restart(save, schema, restart)
            restart.assert_not_called()
            if failed_stage == "backup":
                schema.assert_not_called()

    def test_restart_order(self):
        order = []
        backup_then_restart(
            lambda: order.append("backup"),
            lambda: order.append("schema"),
            lambda: order.append("restart"),
        )
        self.assertEqual(order, ["backup", "schema", "restart"])


if __name__ == "__main__":
    unittest.main()
