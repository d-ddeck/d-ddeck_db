"""Verify clean install and populated initial-schema upgrade in temporary SQLite DBs.

Run from backend: python scripts/test_migrations.py
No application database is read or changed.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

from sqlalchemy import create_engine, inspect, text

ROOT = Path(__file__).resolve().parents[1]


def alembic(db: Path, *args: str) -> None:
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+pysqlite:///{db.as_posix()}",
        "ENVIRONMENT": "test",
        "DEBUG": "false",
    }
    subprocess.run(
        [sys.executable, "-m", "alembic", *args], cwd=ROOT, env=env, check=True
    )


def check_data(db: Path) -> None:
    engine = create_engine(f"sqlite+pysqlite:///{db.as_posix()}")
    try:
        with engine.connect() as conn:
            assert conn.execute(text("SELECT name, set_no FROM assets")).one() == (
                "기존 장비",
                0,
            )
            assert conn.execute(
                text("SELECT title, is_rental, rental_returned FROM service_tickets")
            ).one() == ("기존 접수", 0, 0)
            assert (
                conn.execute(text("SELECT content FROM service_logs")).scalar_one()
                == "기존 이력"
            )
            assert not conn.execute(text("PRAGMA foreign_key_check")).all()
            assert conn.execute(text("PRAGMA integrity_check")).scalar_one() == "ok"
    finally:
        engine.dispose()


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="ddeck-migrations-") as tmp:
        fresh = Path(tmp) / "fresh.db"
        alembic(fresh, "upgrade", "head")
        alembic(fresh, "check")
        engine = create_engine(f"sqlite+pysqlite:///{fresh.as_posix()}")
        assert len(set(inspect(engine).get_table_names()) - {"alembic_version"}) == 30
        engine.dispose()
        print("PASS: clean install, 30 tables, no model drift", flush=True)

        production_env = {
            **os.environ,
            "DATABASE_URL": f"sqlite+pysqlite:///{fresh.as_posix()}",
            "ENVIRONMENT": "production",
            "DEBUG": "false",
            "SCHEDULER_ENABLED": "false",
            "SECRET_KEY": "migration-test-key-not-for-deployment-1234567890",
            "CORS_ORIGINS": "http://localhost",
            "FIRST_SUPERADMIN_PASSWORD": "Test-admin-1234",
            "STORAGE_DIR": str(Path(tmp) / "storage"),
        }
        subprocess.run(
            [
                sys.executable,
                "-c",
                """
from unittest.mock import patch
from fastapi.testclient import TestClient
from app.main import app
from app.models import Base
with patch.object(Base.metadata, 'create_all', side_effect=AssertionError('production DDL')):
    with TestClient(app) as client:
        assert client.get('/healthz').status_code == 200
""",
            ],
            cwd=ROOT,
            env=production_env,
            check=True,
        )
        print(
            "PASS: production starts on migrated schema without create_all", flush=True
        )

        old = Path(tmp) / "old.db"
        alembic(old, "upgrade", "846cbbc04086")
        engine = create_engine(f"sqlite+pysqlite:///{old.as_posix()}")
        asset_id, ticket_id = uuid.uuid4().hex, uuid.uuid4().hex
        with engine.begin() as conn:
            conn.execute(
                text(
                    "INSERT INTO assets (id, asset_no, name, status, quantity, unit) "
                    "VALUES (:id, 'EQ-OLD', '기존 장비', 'IN_STOCK', 1, 'EA')"
                ),
                {"id": asset_id},
            )
            conn.execute(
                text(
                    "INSERT INTO service_tickets "
                    "(id, ticket_no, title, asset_id, status, priority, channel, received_at, is_warranty) "
                    "VALUES (:id, 'AS-OLD', '기존 접수', :asset, 'RECEIVED', 'NORMAL', 'PHONE', CURRENT_TIMESTAMP, 1)"
                ),
                {"id": ticket_id, "asset": asset_id},
            )
            conn.execute(
                text(
                    "INSERT INTO service_logs (id, ticket_id, content) VALUES (:id, :ticket, '기존 이력')"
                ),
                {"id": uuid.uuid4().hex, "ticket": ticket_id},
            )
        engine.dispose()
        alembic(old, "upgrade", "head")
        alembic(old, "check")
        check_data(old)
        print(
            "PASS: populated initial-schema upgrade preserves rows and foreign keys",
            flush=True,
        )
        alembic(old, "downgrade", "846cbbc04086")
        alembic(old, "upgrade", "head")
        alembic(old, "check")
        check_data(old)
        print("PASS: downgrade and re-upgrade", flush=True)

        # Adopt the exact previously shipped create_all schema, then migrate.
        baseline = Path(tmp) / "baseline.db"
        alembic(baseline, "upgrade", "2cca8909675d")
        baseline_env = {
            **os.environ,
            "DATABASE_URL": f"sqlite+pysqlite:///{baseline.as_posix()}",
            "ENVIRONMENT": "test",
            "DEBUG": "false",
        }
        baseline_engine = create_engine(baseline_env["DATABASE_URL"])
        with baseline_engine.begin() as conn:
            conn.execute(text("DROP TABLE alembic_version"))
        subprocess.run(
            [sys.executable, "scripts/adopt_schema.py", "--stamp"],
            cwd=ROOT,
            env=baseline_env,
            check=True,
        )
        with baseline_engine.connect() as conn:
            assert (
                conn.execute(
                    text("SELECT version_num FROM alembic_version")
                ).scalar_one()
                == "2cca8909675d"
            )
        baseline_engine.dispose()
        alembic(baseline, "upgrade", "head")
        print(
            "PASS: legacy create_all baseline is stamped at its real revision then upgraded",
            flush=True,
        )

        # A create_all installation can only be adopted when its full schema matches.
        env = {
            **os.environ,
            "DATABASE_URL": f"sqlite+pysqlite:///{fresh.as_posix()}",
            "ENVIRONMENT": "test",
            "DEBUG": "false",
        }
        engine = create_engine(env["DATABASE_URL"])
        with engine.begin() as conn:
            conn.execute(text("DROP TABLE alembic_version"))
        engine.dispose()
        subprocess.run(
            [sys.executable, "scripts/adopt_schema.py"], cwd=ROOT, env=env, check=True
        )
        engine = create_engine(env["DATABASE_URL"])
        assert "alembic_version" not in inspect(engine).get_table_names()
        engine.dispose()
        subprocess.run(
            [sys.executable, "scripts/adopt_schema.py", "--stamp"],
            cwd=ROOT,
            env=env,
            check=True,
        )
        alembic(fresh, "check")
        engine = create_engine(env["DATABASE_URL"])
        with engine.begin() as conn:
            conn.execute(text("DROP INDEX uq_assets_category_serial_live"))
        refused_index = subprocess.run(
            [sys.executable, "scripts/adopt_schema.py"],
            cwd=ROOT,
            env=env,
            capture_output=True,
            check=False,
        )
        assert refused_index.returncode != 0
        engine.dispose()
        print(
            "PASS: missing expression index is rejected despite SQLite reflection limits",
            flush=True,
        )
        engine = create_engine(env["DATABASE_URL"])
        with engine.begin() as conn:
            conn.execute(text("DROP TABLE worklog_drafts"))
        engine.dispose()
        refused = subprocess.run(
            [sys.executable, "scripts/adopt_schema.py", "--stamp"],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert refused.returncode != 0 and "Refusing to stamp" in refused.stderr
        print(
            "PASS: adoption is read-only by default and rejects incomplete schemas",
            flush=True,
        )


if __name__ == "__main__":
    main()
