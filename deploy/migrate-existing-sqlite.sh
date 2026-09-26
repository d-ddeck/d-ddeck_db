#!/usr/bin/env bash
# Apply a rehearsed migration to the legacy backend/ddeck.db installation.
# Stop ALL writers first. Run as the installation owner, not with sudo.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../backend"
[[ "$EUID" -ne 0 ]] || { echo 'Run as the installation owner, without sudo.' >&2; exit 1; }
PY="$PWD/.venv-linux/bin/python"
[[ -x "$PY" && -f .env && -f ddeck.db ]] || { echo 'Expected .venv-linux, .env and ddeck.db in backend.' >&2; exit 1; }
command -v ss >/dev/null
assert_stopped() {
  if systemctl is-active --quiet ddeck; then
    echo 'Stop ddeck.service first.' >&2; exit 1
  fi
  if [[ -n "$(ss -H -ltn 'sport = :8000')" ]]; then
    echo 'Port 8000 is in use. Stop the manual server first.' >&2; exit 1
  fi
}
assert_stopped
export DEBUG=false
# Refuse environment overrides pointing to a different DB; do not source .env.
STORAGE_PATH="$("$PY" - <<'PY'
from pathlib import Path
from sqlalchemy.engine import make_url
from app.core.config import settings
url = make_url(settings.DATABASE_URL)
if url.get_backend_name() != 'sqlite' or url.query or Path(url.database or '').resolve() != Path('ddeck.db').resolve():
    raise SystemExit('This script only supports the configured backend/ddeck.db without URL options.')
print(Path(settings.STORAGE_DIR).resolve())
PY
)"
[[ -d "$STORAGE_PATH" ]] || { echo 'Configured attachment directory is missing.' >&2; exit 1; }
mkdir -p "$HOME/ddeck-backups"
BACKUP_DIR="$(mktemp -d "$HOME/ddeck-backups/migration-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
echo "Backup directory: $BACKUP_DIR"
cp -a .env "$BACKUP_DIR/.env"
cp -a "$STORAGE_PATH" "$BACKUP_DIR/storage"
"$PY" "$SCRIPT_DIR/prepare_legacy_sqlite.py" --database "$PWD/ddeck.db" --output "$BACKUP_DIR/database"
[[ -f "$BACKUP_DIR/database/VERIFIED" ]]
assert_stopped
# Refuse replacement if another writer changed source rows during preparation.
"$PY" - "$SCRIPT_DIR" "$BACKUP_DIR/database/original.db" "$PWD/ddeck.db" <<'PYCODE'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from prepare_legacy_sqlite import verify_rows
verify_rows(Path(sys.argv[2]), Path(sys.argv[3]))
PYCODE
# All migrations and data checks have succeeded on the copy before replacement.
"$PY" "$SCRIPT_DIR/sqlite_backup.py" restore "$BACKUP_DIR/database/upgraded.db" "$PWD/ddeck.db"
if ! "$PY" "$SCRIPT_DIR/check_service_schema.py"; then
  echo 'Post-apply schema check failed. Restoring original DB.' >&2
  "$PY" "$SCRIPT_DIR/sqlite_backup.py" restore "$BACKUP_DIR/database/original.db" "$PWD/ddeck.db"
  exit 1
fi
echo 'DB UPDATE COMPLETE. Service is still stopped.'
echo "Original database: $BACKUP_DIR/database/original.db"
echo 'Next: sudo systemctl reset-failed ddeck && sudo systemctl start ddeck'
