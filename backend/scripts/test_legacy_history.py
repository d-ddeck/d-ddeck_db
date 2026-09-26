"""Synthetic supplemental import verifies original names, inactive stores and idempotency."""

import os
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def main():
    with tempfile.TemporaryDirectory(prefix="ddeck-history-") as temporary:
        os.environ.update(
            DATABASE_URL=f"sqlite:///{temporary}/target.db",
            DEBUG="false",
            ENVIRONMENT="test",
        )
        from app.core.database import SessionLocal, engine
        from app.core.security import now_utc
        from app.models import Base
        from app.models.admin import AuditLog
        from app.models.board import Board
        from app.models.inventory import Asset, AssetMovement
        from app.models.service import ServiceTicket
        from app.models.store import Store
        from app.models.user import User
        from legacy_history import migrate
        from migrate_from_legacy import Stats, code_for, to_utc
        from sqlalchemy import func, select

        Base.metadata.create_all(engine)
        source = sqlite3.connect(":memory:")
        source.executescript("""
            CREATE TABLE change_log(id, record_no, at, "by", action, field, old, new);
            INSERT INTO change_log VALUES(1, 10, '2026-09-01', 'former-user', 'edit', 'title', 'old', 'new');
            CREATE TABLE asset_log(id, asset_id, at, "by", action, detail, record_no);
            INSERT INTO asset_log VALUES(1, 1, '2026-09-01', 'known', 'move', 'warehouse', 10);
            CREATE TABLE records(no, updated_by);
            INSERT INTO records VALUES(10, 'former-user'), (11, 'known');
            CREATE TABLE stores(name, active);
            INSERT INTO stores VALUES('old store', 0);
            CREATE TABLE lists(kind, value, sort, active);
            INSERT INTO lists VALUES('doc_category', 'empty board', 1, 1);
        """)
        with SessionLocal() as db:
            user = User(
                email="known@test.local", full_name="Known", password_hash="unused"
            )
            store = Store(name="old store")
            asset = Asset(asset_no="AST-L-00001", name="asset")
            first = ServiceTicket(
                ticket_no="AS-10", legacy_no=10, title="first", received_at=now_utc()
            )
            second = ServiceTicket(
                ticket_no="AS-11", legacy_no=11, title="second", received_at=now_utc()
            )
            db.add_all([user, store, asset, first, second])
            db.commit()
            for _ in range(2):
                migrate(db, source, Stats(), {"known": user}, to_utc, code_for)
                db.commit()
                assert db.scalar(select(func.count(AuditLog.id))) == 2
                assert db.scalar(select(func.count(AssetMovement.id))) == 1
                assert db.scalar(select(func.count(Board.id))) == 1
                assert second.updated_by_id == user.id
                assert not store.is_active
                assert (
                    db.scalar(
                        select(AuditLog).where(AuditLog.summary.like("%최종 수정자%"))
                    ).changes["updated_by"][1]
                    == "former-user"
                )
        source.close()
        engine.dispose()
        print(
            "PASS: supplemental import twice preserves names, row counts, empty boards and inactive stores"
        )


if __name__ == "__main__":
    main()
