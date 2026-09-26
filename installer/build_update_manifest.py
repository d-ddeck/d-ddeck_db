"""Sign both platform installers with the release-only Ed25519 key."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[1]


def build(directory, version, build_number, private_key):
    key = Ed25519PrivateKey.from_private_bytes(private_key)
    public = base64.b64encode(key.public_key().public_bytes_raw()).decode()
    for path in (
        ROOT / "backend/app/core/update_public_key.txt",
        ROOT / "app/assets/update_public_key.txt",
    ):
        if path.read_text().strip() != public:
            raise ValueError("Signing key does not match pinned client/server key")
    artifacts = {}
    for platform, name in [
        ("windows", f"ddeck-setup-{version}.exe"),
        ("android", f"ddeck-{version}-arm64.apk"),
    ]:
        path = directory / name
        with path.open("rb") as file:
            digest = hashlib.file_digest(file, "sha256").hexdigest()
        artifacts[platform] = {
            "filename": name,
            "size": path.stat().st_size,
            "sha256": digest,
        }
    payload = json.dumps(
        {
            "schema": 1,
            "version": version,
            "build": build_number,
            "release": f"{version}-{build_number}",
            "artifacts": artifacts,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    envelope = {
        "payload": base64.b64encode(payload).decode(),
        "signature": base64.b64encode(key.sign(payload)).decode(),
    }
    (directory / "update-manifest.json").write_text(json.dumps(envelope) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    import re

    match = re.search(
        r"^version: (\d+\.\d+\.\d+)\+(\d+)$",
        (ROOT / "app/pubspec.yaml").read_text(),
        re.MULTILINE,
    )
    if not match or match[1] != args.version:
        raise SystemExit("pubspec version mismatch")
    build(
        args.directory,
        args.version,
        int(match[2]),
        base64.b64decode(os.environ["UPDATE_SIGNING_KEY_BASE64"], validate=True),
    )
