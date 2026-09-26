"""Portable backup/restore regressions; operates exclusively in temporary folders."""

from __future__ import annotations

import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from sqlite_backup import restore, snapshot


class SQLiteBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ddeck-backup-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "원본 ' snapshot.db"
        with closing(sqlite3.connect(self.source)) as db, db:
            db.execute("CREATE TABLE records (value TEXT)")
            db.execute("INSERT INTO records VALUES ('backup')")

    def read(self, path):
        with closing(sqlite3.connect(path)) as db:
            return db.execute("SELECT value FROM records").fetchall()

    def test_snapshot_includes_live_wal(self):
        live = sqlite3.connect(self.source)
        try:
            live.execute("PRAGMA journal_mode=WAL")
            live.execute("INSERT INTO records VALUES ('wal')")
            live.commit()
            destination = self.root / "copy.db"
            snapshot(self.source, destination)
            self.assertEqual(self.read(destination), [("backup",), ("wal",)])
        finally:
            live.close()

    def test_restore_discards_stale_wal(self):
        destination = self.root / "running.db"
        snapshot(self.source, destination)
        # Simulate an unclean shutdown that leaves committed WAL beside the DB.
        subprocess.run(
            [
                sys.executable,
                "-c",
                """
import os, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute('PRAGMA journal_mode=WAL')
conn.execute('PRAGMA wal_autocheckpoint=0')
conn.execute("INSERT INTO records VALUES ('stale WAL')")
conn.commit()
os._exit(0)
""",
                str(destination),
            ],
            check=True,
        )
        self.assertTrue(Path(str(destination) + "-wal").exists())
        restore(self.source, destination)
        self.assertEqual(self.read(destination), [("backup",)])
        self.assertFalse(Path(str(destination) + "-wal").exists())
        self.assertFalse(Path(str(destination) + "-shm").exists())

    def test_bad_restore_preserves_existing_database_and_sidecars(self):
        bad = self.root / "bad.db"
        bad.write_text("not a database")
        wal = Path(str(self.source) + "-wal")
        wal.write_bytes(b"preserve me")
        before = self.source.read_bytes()
        with self.assertRaises(sqlite3.DatabaseError):
            restore(bad, self.source)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(wal.read_bytes(), b"preserve me")

    def test_missing_source_is_not_created(self):
        missing = self.root / "missing.db"
        with self.assertRaises(sqlite3.OperationalError):
            snapshot(missing, self.root / "target.db")
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main()
