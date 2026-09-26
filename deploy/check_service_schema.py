"""Translate Alembic failures into systemd ExecCondition's non-retrying exit 1."""

import subprocess
import sys


def main():
    try:
        result = subprocess.run([sys.executable, '-m', 'alembic', 'check'], check=False)
    except OSError:
        print('Cannot run schema check; server startup skipped.', file=sys.stderr)
        return 1
    if result.returncode:
        print('Schema check failed; server startup skipped. Complete DB migration before starting ddeck.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
