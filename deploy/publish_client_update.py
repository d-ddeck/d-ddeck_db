"""Publish verified installers from a downloaded GitHub release bundle.

The server also does this on its own (app.services.client_update_sync); this
command is for publishing by hand or cleaning up old installers.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from app.core.client_updates import prune, publish

if __name__ == "__main__":
    import logging

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--bundle", type=Path)
    action.add_argument(
        "--prune-only",
        action="store_true",
        help="게시하지 않고 최신 버전 외의 예전 설치 파일만 지운다",
    )
    args = parser.parse_args()
    from app.core.config import settings

    destination = Path(settings.STORAGE_DIR) / "client-updates"
    if args.prune_only:
        prune(destination)
    else:
        publish(args.bundle, destination)
