"""Provision server-PC-only administrator sign-in for a desktop OS account.
Run on the server as the desktop owner; never copy the generated credential.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.api.v1.auth import _find_login_user
from app.core.database import SessionLocal
from app.services.local_admin import enable, registry_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account", default="admin")
    parser.add_argument("--profile-dir", type=Path, default=Path.home())
    parser.add_argument("--server-url", default="http://127.0.0.1:8000")
    parser.add_argument("--disable", action="store_true")
    args = parser.parse_args()
    if args.disable:
        registry_path().unlink(missing_ok=True)
        (args.profile_dir / ".ddeck/local-admin-login.json").unlink(missing_ok=True)
        print(
            "Server PC automatic login disabled. Existing sessions can be revoked in account settings."
        )
        return
    with SessionLocal() as db:
        user = _find_login_user(db, args.account.lower().strip())
        if user is None:
            raise SystemExit(
                "Admin account not found or ambiguous. Use the complete email address."
            )
        enable(user, args.profile_dir, args.server_url)
    print(
        "Server PC automatic admin login configured for this OS profile. Credential contents are not displayed."
    )


if __name__ == "__main__":
    main()
