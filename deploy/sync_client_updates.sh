#!/usr/bin/env bash
# Run as the deployment owner. gh authentication stays on the server.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../backend"
PY="$PWD/.venv-linux/bin/python"
[[ -x "$PY" ]] || PY="$PWD/.venv/bin/python"
[[ -x "$PY" ]] || { echo 'Backend virtualenv not found.' >&2; exit 1; }
BUNDLE_DIR="$(mktemp -d)"
trap 'rm -rf "$BUNDLE_DIR"' EXIT
RELEASE_ARGS=()
if [[ $# -gt 0 ]]; then
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected vX.Y.Z'; exit 1; }
  RELEASE_ARGS+=("$1")
fi
# Resolve one immutable tag first so a concurrent release cannot mix files.
TAG="$(gh release view "${RELEASE_ARGS[@]}" --repo kmeans12345-cell/d-ddeck_db --json tagName --jq .tagName)"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
gh release download "$TAG" --repo kmeans12345-cell/d-ddeck_db --dir "$BUNDLE_DIR" \
  --pattern update-manifest.json
if DEBUG=false "$PY" - "$BUNDLE_DIR/update-manifest.json" <<'PYCODE'
import hashlib, json, sys
from pathlib import Path
from app.core.client_updates import verify_manifest
from app.core.config import settings
try:
    incoming = json.loads(Path(sys.argv[1]).read_text())
    metadata = verify_manifest(incoming)
    root = Path(settings.STORAGE_DIR) / 'client-updates'
    if json.loads((root / 'latest.json').read_text()) != incoming:
        raise ValueError('New release')
    for artifact in metadata['artifacts'].values():
        path = root / metadata['release'] / artifact['filename']
        with path.open('rb') as file:
            digest = hashlib.file_digest(file, 'sha256').hexdigest()
        if digest != artifact['sha256'] or path.stat().st_size != artifact['size']:
            raise ValueError('File mismatch')
except (OSError, ValueError, KeyError):
    sys.exit(1)
print('Client update already published and verified.')
PYCODE
then
  exit 0
fi
gh release download "$TAG" --repo kmeans12345-cell/d-ddeck_db --dir "$BUNDLE_DIR" \
  --pattern 'ddeck-setup-*.exe' --pattern 'ddeck-*-arm64.apk'
DEBUG=false "$PY" "$SCRIPT_DIR/publish_client_update.py" --bundle "$BUNDLE_DIR"
