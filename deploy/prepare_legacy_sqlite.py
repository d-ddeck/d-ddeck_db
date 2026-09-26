"""Build a verified upgraded COPY of a legacy DB. Never modify the source DB."""

import argparse
import os
import sqlite3
import subprocess
import sys
from contextlib import closing
from pathlib import Path

from sqlite_backup import snapshot, validate

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    'from_store_id': 'stores', 'to_store_id': 'stores',
    'from_status_item_id': 'code_items', 'to_status_item_id': 'code_items',
}


def ident(name):
    return '"' + name.replace('"', '""') + '"'


def verify_rows(original, upgraded):
    """Every pre-existing value must survive; new columns are checked by Alembic."""
    with closing(sqlite3.connect(upgraded)) as db:
        db.execute('ATTACH DATABASE ? AS original', (str(original),))
        tables = db.execute("SELECT name FROM original.sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'alembic_version'").fetchall()
        for (table,) in tables:
            columns = db.execute(f'PRAGMA original.table_info({ident(table)})').fetchall()
            names = ','.join(ident(c[1]) for c in columns)
            before = f'SELECT {names} FROM original.{ident(table)}'
            after = f'SELECT {names} FROM main.{ident(table)}'
            count_before = db.execute(f'SELECT count(*) FROM original.{ident(table)}').fetchone()
            count_after = db.execute(f'SELECT count(*) FROM main.{ident(table)}').fetchone()
            if count_before != count_after or db.execute(f'{before} EXCEPT {after}').fetchone() or db.execute(f'{after} EXCEPT {before}').fetchone():
                raise RuntimeError(f'Original values changed in {table}; do not apply')
        if db.execute('PRAGMA main.foreign_key_check').fetchone():
            raise RuntimeError('Foreign key violation; do not apply')
    validate(upgraded)
    return len(tables)


def repair_copy(path):
    sys.path.insert(0, str(ROOT / 'backend'))
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext
    from alembic.operations import Operations
    from sqlalchemy import create_engine, text
    from sqlalchemy.engine import URL

    from scripts.adopt_schema import metadata_at_baseline

    engine = create_engine(URL.create('sqlite+pysqlite', database=str(path)))
    try:
        with engine.begin() as connection:
            context = MigrationContext.configure(connection, opts={'compare_type': True, 'compare_server_default': True})
            diffs = compare_metadata(context, metadata_at_baseline())
            missing = {}
            for diff in diffs:
                if diff[0] != 'add_fk':
                    raise RuntimeError('Unexpected schema difference; refusing automatic repair')
                fk = diff[1]
                elements = list(fk.elements)
                if fk.table.name != 'asset_movements' or len(elements) != 1:
                    raise RuntimeError('Unexpected foreign key difference')
                column = elements[0].parent.name
                target = EXPECTED.get(column)
                if not target or elements[0].target_fullname != target + '.id' or fk.ondelete != 'SET NULL':
                    raise RuntimeError('Unexpected foreign key definition')
                missing[column] = target
            if connection.exec_driver_sql("SELECT count(*) FROM sqlite_master WHERE type='trigger'").scalar():
                raise RuntimeError('Custom triggers require manual review')
            if connection.exec_driver_sql('PRAGMA foreign_key_check').first():
                raise RuntimeError('Existing foreign key violations require manual review')
            for column, target in missing.items():
                count = connection.execute(text(f'SELECT count(*) FROM asset_movements m LEFT JOIN {target} t ON m.{column}=t.id WHERE m.{column} IS NOT NULL AND t.id IS NULL')).scalar()
                if count:
                    raise RuntimeError(f'{column}: {count} orphan references; no records changed')
            if missing:
                with Operations(context).batch_alter_table('asset_movements', recreate='always') as batch:
                    for column, target in missing.items():
                        batch.create_foreign_key(f'fk_asset_movements_{column}', target, [column], ['id'], ondelete='SET NULL')
            if compare_metadata(context, metadata_at_baseline()):
                raise RuntimeError('Baseline verification failed')
    finally:
        engine.dispose()


def prepare(source, output):
    source = source.resolve()
    if not source.is_file():
        raise RuntimeError('Source DB does not exist')
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    original, upgraded = output / 'original.db', output / 'upgraded.db'
    snapshot(source, original)
    snapshot(original, upgraded)
    original.chmod(0o600)
    upgraded.chmod(0o600)
    # Explicit copy URL overrides .env for every migration process.
    from sqlalchemy.engine import URL
    url = URL.create('sqlite+pysqlite', database=str(upgraded.resolve())).render_as_string(hide_password=False)
    os.environ['DATABASE_URL'] = url
    os.environ['DEBUG'] = 'false'
    repair_copy(upgraded)
    commands = [
        [sys.executable, 'scripts/adopt_schema.py', '--stamp'],
        [sys.executable, '-m', 'alembic', 'upgrade', 'head'],
        [sys.executable, '-m', 'alembic', 'check'],
        [sys.executable, 'scripts/adopt_schema.py'],
    ]
    for command in commands:
        subprocess.run(command, cwd=ROOT / 'backend', check=True, env=os.environ.copy())
    count = verify_rows(original, upgraded)
    (output / 'VERIFIED').write_text(f'{count} tables: original values preserved; schema and integrity verified.\n')
    print(f'VERIFIED: {count} tables. Source DB unchanged. Copy: {upgraded}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New private directory; must not exist')
    args = parser.parse_args()
    os.umask(0o077)
    prepare(args.database, args.output)
