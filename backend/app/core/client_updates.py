"""Signed release metadata shared by the download API and deployment tooling."""

import base64
import json
import re
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PUBLIC_KEY = Path(__file__).with_name("update_public_key.txt").read_text().strip()


def verify_manifest(envelope: dict) -> dict:
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    key = base64.b64decode(PUBLIC_KEY)
    Ed25519PublicKey.from_public_bytes(key).verify(signature, payload)
    data = json.loads(payload)
    if data.get("schema") != 1 or not re.fullmatch(r"\d+\.\d+\.\d+", data["version"]):
        raise ValueError("Invalid update version")
    if type(data["build"]) is not int or data["build"] < 1:
        raise ValueError("Invalid build")
    if data["release"] != f"{data['version']}-{data['build']}":
        raise ValueError("Invalid release directory")
    if set(data["artifacts"]) != {"windows", "android"}:
        raise ValueError("Both client platforms are required")
    for platform, artifact in data["artifacts"].items():
        expected = (
            f"ddeck-setup-{data['version']}.exe"
            if platform == "windows"
            else f"ddeck-{data['version']}-arm64.apk"
        )
        if artifact["filename"] != expected or not re.fullmatch(
            "[0-9a-f]{64}", artifact["sha256"]
        ):
            raise ValueError("Invalid artifact")
        if type(artifact["size"]) is not int or not 0 < artifact["size"] <= 1024**3:
            raise ValueError("Invalid artifact size")
    return data
