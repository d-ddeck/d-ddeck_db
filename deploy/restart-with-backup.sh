#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for VENV in .venv-linux .venv; do
  PYTHON="$ROOT/backend/$VENV/bin/python"
  if [[ -x "$PYTHON" ]]; then
    # Match the registered service, which loads settings from backend/.env.
    exec env -u DEBUG -u DATABASE_URL -u ENVIRONMENT "$PYTHON" "$ROOT/deploy/restart_with_backup.py" "$@"
  fi
done
echo '서버 가상환경을 찾지 못했습니다.' >&2
exit 1
