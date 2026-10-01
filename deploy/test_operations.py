"""Exercise TLS validation and real SQLite rollback with only system calls mocked."""

import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

import backup_bundle
import configure_https
import harden_service
import update_snapshot


class OperationsTests(unittest.TestCase):
    def test_tls_rejects_injection_and_requires_network(self):
        for domain, networks in [
            ("example.com; include bad", ["10.0.0.0/8"]),
            ("example.com", []),
            ("example.com", ["bad"]),
            ("example.com", ["0.0.0.0/0"]),
            ("example.com", ["::/0"]),
        ]:
            with self.assertRaises(ValueError):
                configure_https.render(domain, networks, "/cert.pem", "/key.pem", 8000)
        value = configure_https.render(
            "example.com", ["10.8.0.5/24"], "/cert.pem", "/key.pem", 8000
        )
        self.assertIn("allow 10.8.0.0/24;", value)
        self.assertIn("deny all;", value)
        self.assertIn("proxy_pass http://127.0.0.1:8000", value)

    def test_legacy_db_migration_and_narrow_service_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "backend").mkdir()
            (root / "backend/.env").write_text(
                "DATABASE_URL=sqlite:///./ddeck.db\nSTORAGE_DIR=../storage\n"
            )
            with closing(sqlite3.connect(root / "backend/ddeck.db")) as db, db:
                db.execute("CREATE TABLE sample(value TEXT)")
                db.execute("INSERT INTO sample VALUES ('retained')")
            unit = root / "service.unit"
            unit.write_text(
                f"[Unit]\nDescription=App\n[Service]\nExecStart=/python -m uvicorn app.main:app --port 8000\nReadWritePaths={root}/backend\n"
            )
            harden_service.harden(root, unit)
            with closing(sqlite3.connect(root / "data/ddeck.db")) as db:
                self.assertEqual(
                    db.execute("SELECT value FROM sample").fetchone()[0], "retained"
                )
            self.assertIn(
                str(root / "data/ddeck.db"), (root / "backend/.env").read_text()
            )
            self.assertNotIn(f"ReadWritePaths={root}/backend", unit.read_text())
            self.assertIn("--no-access-log", unit.read_text())
            self.assertIn("StartLimitBurst=10", unit.read_text())
            harden_service.harden(root, unit)

    def test_pg_restore_uses_target_host_and_transaction_without_password_argument(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "backend").mkdir()
            (root / "backend/.env").write_text(
                "DATABASE_URL=postgresql://worker:example-password@db.internal:5544/target_db\n"
            )
            dump = root / "db.dump"
            dump.write_bytes(b"mock")
            with patch.object(backup_bundle.subprocess, "run") as execute:
                backup_bundle.restore_postgres(root, dump)
            command = execute.call_args.args[0]
            self.assertIn("--single-transaction", command)
            self.assertIn("target_db", command)
            self.assertNotIn("example-password", " ".join(command))
            self.assertEqual(execute.call_args.kwargs["env"]["PGHOST"], "db.internal")
            self.assertEqual(execute.call_args.kwargs["env"]["PGPORT"], "5544")

    def test_rollback_restores_code_database_custom_storage_and_unit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "backend").mkdir()
            (root / "custom-storage").mkdir()
            (root / "backend/.env").write_text(
                "DATABASE_URL=sqlite:///../data/app.db\nSTORAGE_DIR=../custom-storage\n"
            )
            (root / "backend/version.txt").write_text("old code")
            (root / "data").mkdir()
            with closing(sqlite3.connect(root / "data/app.db")) as db, db:
                db.execute("CREATE TABLE sample(value TEXT)")
                db.execute("INSERT INTO sample VALUES ('old row')")
            (root / "custom-storage/photo").write_text("old photo")
            unit = root / "service.unit"
            unit.write_text("old unit")
            archive = backup_bundle.backup(root, data_only=True)
            data_name = "drive_20260929_000000_000000.zip"
            cloud = {data_name: archive.read_bytes()}
            archive.unlink()
            private = root / "backups/.drive-private"
            private.mkdir()
            (private / "last_cloud_backup.json").write_text(
                json.dumps({"name": data_name, "target": "test:backup"})
            )

            def upload(root, path):
                cloud[path.name] = path.read_bytes()
                return {"name": path.name, "target": "test:backup"}

            def download(root, metadata, destination):
                destination.write_bytes(cloud[metadata["name"]])

            with (
                patch.object(
                    update_snapshot.cloud_backup, "upload_archive", side_effect=upload
                ),
                patch.object(
                    update_snapshot.cloud_backup,
                    "download_archive",
                    side_effect=download,
                ),
            ):
                snapshot = update_snapshot.prepare(root, unit)
            self.assertEqual([p.name for p in snapshot.iterdir()], ["snapshot.json"])
            (root / "backend/version.txt").write_text("broken code")
            (root / "custom-storage/photo").write_text("broken photo")
            unit.write_text("broken unit")
            with closing(sqlite3.connect(root / "data/app.db")) as db, db:
                db.execute("UPDATE sample SET value='broken row'")
            with (
                patch.object(update_snapshot.subprocess, "run") as execute,
                patch.object(update_snapshot, "verify_running") as health,
                patch.object(
                    update_snapshot.cloud_backup,
                    "download_archive",
                    side_effect=download,
                ),
            ):
                update_snapshot.recover(root, snapshot)
            health.assert_called_once_with(8000)
            self.assertEqual((root / "backend/version.txt").read_text(), "old code")
            self.assertEqual((root / "custom-storage/photo").read_text(), "old photo")
            self.assertEqual(unit.read_text(), "old unit")
            with closing(sqlite3.connect(root / "data/app.db")) as db:
                self.assertEqual(
                    db.execute("SELECT value FROM sample").fetchone()[0], "old row"
                )
            self.assertEqual(
                execute.call_args_list[0].args[0], ["systemctl", "stop", "ddeck"]
            )
            self.assertEqual(
                execute.call_args_list[-1].args[0], ["systemctl", "start", "ddeck"]
            )
            self.assertTrue(
                json.loads((snapshot / "snapshot.json").read_text())["cloud"]
            )


if __name__ == "__main__":
    unittest.main()
