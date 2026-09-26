import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from prepare_legacy_sqlite import verify_rows
from sqlite_backup import snapshot


class PreservationTests(unittest.TestCase):
    def test_existing_value_change_and_row_loss_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            original, upgraded = Path(tmp) / 'before.db', Path(tmp) / 'after.db'
            with closing(sqlite3.connect(original)) as db, db:
                db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT)')
                db.execute("INSERT INTO items VALUES(1, 'keep')")
            snapshot(original, upgraded)
            with closing(sqlite3.connect(upgraded)) as db, db:
                db.execute('ALTER TABLE items ADD COLUMN extra TEXT')
            self.assertEqual(verify_rows(original, upgraded), 1)
            with closing(sqlite3.connect(upgraded)) as db, db:
                db.execute("UPDATE items SET value='changed'")
            with self.assertRaises(RuntimeError):
                verify_rows(original, upgraded)
            with closing(sqlite3.connect(upgraded)) as db, db:
                db.execute('DELETE FROM items')
            with self.assertRaises(RuntimeError):
                verify_rows(original, upgraded)

    def test_new_orphan_foreign_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            original, upgraded = Path(tmp) / 'before.db', Path(tmp) / 'after.db'
            with closing(sqlite3.connect(original)) as db, db:
                db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)')
            snapshot(original, upgraded)
            with closing(sqlite3.connect(upgraded)) as db, db:
                db.execute('CREATE TABLE children(id INTEGER REFERENCES items(id))')
                db.execute('INSERT INTO children VALUES(1)')
            with self.assertRaises(RuntimeError):
                verify_rows(original, upgraded)
