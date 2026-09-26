"""Cron-compatible health/backup/disk monitor; nonzero exit indicates action needed."""

import argparse
import json
import shutil
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def check(root, url):
    errors = []
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            if json.load(response).get("status") != "ok":
                errors.append("API unhealthy")
    except Exception:  # noqa: BLE001 - isolate background/diagnostic failures
        errors.append("API unreachable")
    try:
        last = json.loads((root / "backups/last_success.json").read_text())
        age = datetime.now(timezone.utc) - datetime.fromisoformat(last["finished_at"])
        if age.total_seconds() >= 36 * 3600:
            errors.append("Backup older than 36 hours")
    except (OSError, ValueError, KeyError):
        errors.append("No verified backup")
    if (root / "backups/LAST_FAILED").exists():
        errors.append("Last backup failed")
    if shutil.disk_usage(root).free < 1024**3:
        errors.append("Less than 1 GiB free disk")
    return errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/opt/ddeck"))
    parser.add_argument("--url", default="http://127.0.0.1:8000/healthz")
    args = parser.parse_args()
    errors = check(args.root, args.url)
    print(json.dumps({"status": "failed" if errors else "ok", "errors": errors}))
    raise SystemExit(bool(errors))
