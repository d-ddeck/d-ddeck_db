"""SQLite snapshot/restore helper. Stop the application before using restore.

Paths are CLI arguments, never interpolated Python or SQLite source text.
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import tempfile
from contextlib import closing
from pathlib import Path


def validate(path: Path) -> None:
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        result = db.execute("PRAGMA integrity_check").fetchall()
        if result != [("ok",)]:
            raise RuntimeError(f"SQLite integrity check failed: {result}")


def snapshot(source: Path, destination: Path) -> None:
    # mode=ro ensures a typo cannot silently create an empty source database.
    with (
        closing(
            sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)
        ) as src,
        closing(sqlite3.connect(destination)) as dst,
    ):
        src.backup(dst)
    validate(destination)


def restore(source: Path, destination: Path) -> None:
    validate(source)
    handle, name = tempfile.mkstemp(
        prefix=".ddeck-restore-", suffix=".db", dir=destination.parent
    )
    os.close(handle)
    staged = Path(name)
    try:
        snapshot(source, staged)
        # A copied snapshot must never be opened with WAL from the replaced DB.
        for suffix in ("-wal", "-shm"):
            Path(str(destination) + suffix).unlink(missing_ok=True)
        os.replace(staged, destination)
        validate(destination)
    finally:
        staged.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["snapshot", "restore", "validate"])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path, nargs="?")
    args = parser.parse_args()
    if args.action == "validate":
        validate(args.source)
    else:
        if (
            args.destination is None
            or args.destination.resolve() == args.source.resolve()
        ):
            parser.error("provide a destination different from the source")
        (snapshot if args.action == "snapshot" else restore)(
            args.source, args.destination
        )


if __name__ == "__main__":
    main()
