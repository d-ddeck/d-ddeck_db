"""Adopt a fully matching create_all schema without running table creation again.

Read-only by default. After backup and service stop, use --stamp to record head.
A partial or outdated schema is refused; never blindly stamp an existing DB.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import Index, MetaData, create_engine, text
from sqlalchemy.schema import CreateIndex

from alembic import command

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.core.config import settings
from app.models import Base

SERIAL_INDEXES = {"uq_assets_category_serial_live", "uq_assets_serial_no_category_live"}


def metadata_at_baseline(revision="2cca8909675d"):
    metadata = MetaData()
    for table in Base.metadata.sorted_tables:
        table.to_metadata(metadata)
    removed = {
        "audit_logs": ["hidden_at"],
        "asset_movements": ["hidden_at"],
        "attachments": ["photo_category"],
        "events": ["recurrence_parent_id"],
        "notifications": ["push_pending", "push_attempts", "push_after"],
        "service_parts": ["stock_deducted"],
        "stores": ["is_active"],
    }
    if revision == "2cca8909675d":
        removed.update({"refresh_tokens": ["session_id"], "devices": ["session_id"]})
    for name, columns in removed.items():
        table = metadata.tables[name]
        for index in list(table.indexes):
            if any(column in index.columns for column in columns):
                table.indexes.remove(index)
        for constraint in list(table.constraints):
            if any(column in constraint.columns for column in columns):
                table.constraints.remove(constraint)
        for column in columns:
            table._columns.remove(table.c[column])
    for table in metadata.tables.values():
        Index(f"ix_{table.name}_id", table.c.id)
    if revision == "2cca8909675d":
        table = metadata.tables["assets"]
        for index in list(table.indexes):
            if index.name in SERIAL_INDEXES:
                table.indexes.remove(index)
    return metadata


def serial_indexes_match(connection):
    # SQLite reflection skips expression indexes, so compare their DDL explicitly.
    if connection.dialect.name != "sqlite":
        return True

    def normalized(sql):
        return re.sub(r'[\s"`()]+', "", sql or "").lower().replace("<>", "!=")

    actual = dict(
        connection.execute(
            text(
                "SELECT name, sql FROM sqlite_master WHERE type='index' AND name LIKE 'uq_assets_%'"
            )
        ).all()
    )
    for index in Base.metadata.tables["assets"].indexes:
        if index.name in SERIAL_INDEXES:
            expected = str(CreateIndex(index).compile(dialect=connection.dialect))
            if normalized(actual.get(index.name)) != normalized(expected):
                return False
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stamp",
        action="store_true",
        help="Record Alembic head after schema verification",
    )
    args = parser.parse_args()
    engine = create_engine(settings.DATABASE_URL)
    try:
        with engine.connect() as connection:
            context = MigrationContext.configure(
                connection,
                opts={
                    "compare_type": True,
                    "compare_server_default": True,
                },
            )
            differences = compare_metadata(context, Base.metadata)
            revision = "head"
            if not differences and not serial_indexes_match(connection):
                differences = [("missing_or_changed_serial_indexes",)]
            if differences:
                for baseline in ("83c49d102fa1", "2cca8909675d"):
                    baseline_differences = compare_metadata(
                        context, metadata_at_baseline(baseline)
                    )
                    if not baseline_differences and (
                        baseline == "2cca8909675d" or serial_indexes_match(connection)
                    ):
                        differences = []
                        revision = baseline
                        break
        if differences:
            print(
                "Schema differs from current models. Refusing to stamp:",
                file=sys.stderr,
            )
            for difference in differences:
                print(difference, file=sys.stderr)
            raise SystemExit(1)
        print(f"Schema matches verified revision: {revision}.")
        if args.stamp:
            config = Config(str(ROOT / "alembic.ini"))
            config.set_main_option("script_location", str(ROOT / "alembic"))
            command.stamp(config, revision)
            print(
                f"Recorded {revision}; run alembic upgrade head next. No application rows changed."
            )
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
