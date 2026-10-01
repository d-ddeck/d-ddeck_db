"""No real disks, services, or production data touched."""
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from move_database import replace_url
from sqlite_backup import snapshot
from storage_guard import verify


class StorageMoveTests(unittest.TestCase):
    def test_env_preserves_other_values_and_deduplicates_url(self):
        source = b'# DATABASE_URL=comment\nOTHER=unchanged\nDATABASE_URL=old\nDATABASE_URL=duplicate\n'
        result = replace_url(source, 'sqlite+pysqlite:////mnt/data/ddeck.db').decode()
        self.assertIn('OTHER=unchanged', result)
        self.assertEqual(sum(line.startswith('DATABASE_URL=') for line in result.splitlines()), 1)

    def test_missing_or_replaced_disk_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            mount = Path(temp)
            db = mount / 'ddeck.db'
            db.touch()
            with (patch('storage_guard.volume', return_value={'target': '/', 'uuid': 'internal'}),
                  self.assertRaises(RuntimeError)):
                verify(mount, 'external', db)
            with patch('storage_guard.volume', return_value={'target': str(mount), 'uuid': 'external'}):
                verify(mount, 'external', db)
                db.unlink()
                with self.assertRaises(RuntimeError):
                    verify(mount, 'external', db)
                self.assertFalse(db.exists())

    def test_snapshot_includes_committed_wal_data(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / 'source.db', Path(temp) / 'target.db'
            connection = sqlite3.connect(source)
            try:
                connection.execute('PRAGMA journal_mode=WAL')
                connection.execute('CREATE TABLE items (id INTEGER)')
                connection.execute('INSERT INTO items VALUES (42)')
                connection.commit()
                snapshot(source, target)
                with sqlite3.connect(target) as copied:
                    self.assertEqual(copied.execute('SELECT id FROM items').fetchall(), [(42,)])
            finally:
                connection.close()


if __name__ == '__main__':
    unittest.main()
