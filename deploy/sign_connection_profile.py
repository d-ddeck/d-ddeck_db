"""Sign short-lived client connection profiles using an offline administrator key."""
import argparse
import base64
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def sign(url, key, days=2):
    uri = urlsplit(url)
    if (uri.scheme != "https" or not uri.hostname or uri.username or uri.password
            or uri.query or uri.fragment or uri.path not in ("", "/")
            or not 1 <= days <= 7):
        raise ValueError("HTTPS origin and lifetime of 1–7 days are required")
    now = datetime.now(timezone.utc)
    payload = json.dumps({
        "purpose": "ddeck-connection", "schema": 1,
        "server_url": url.rstrip("/"),
        "issued_at": now.isoformat(),
        "expires_at": (now + timedelta(days=days)).isoformat(),
    }, sort_keys=True, separators=(",", ":")).encode()
    return {"payload": base64.b64encode(payload).decode(),
            "signature": base64.b64encode(key.sign(payload)).decode()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--days", type=int, default=2)
    args = parser.parse_args()
    os.umask(0o077)
    key = Ed25519PrivateKey.from_private_bytes(args.key.read_bytes())
    expected = (Path(__file__).resolve().parents[1] /
                "app/assets/connection_public_key.txt").read_text().strip()
    if base64.b64encode(key.public_key().public_bytes_raw()).decode() != expected:
        raise ValueError("Key does not match the application's connection key")
    args.output.write_text(json.dumps(sign(args.url, key, args.days)) + "\n")
    args.output.chmod(0o600)
    print("Signed connection profile created (no credentials included).")


if __name__ == "__main__":
    main()
