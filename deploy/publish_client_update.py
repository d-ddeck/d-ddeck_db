"""Atomically publish verified installers downloaded from a private GitHub release."""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from app.core.client_updates import verify_manifest


def publish(bundle: Path, destination: Path):
    manifest = bundle / "update-manifest.json"
    envelope = json.loads(manifest.read_text())
    metadata = verify_manifest(envelope)
    destination.mkdir(parents=True, exist_ok=True)
    latest_path = destination / "latest.json"
    if latest_path.exists():
        current = verify_manifest(json.loads(latest_path.read_text()))

        def version(data):
            return (*map(int, data["version"].split(".")), data["build"])

        if version(metadata) < version(current):
            raise ValueError("Refusing to publish an older client release")
    with tempfile.TemporaryDirectory(prefix=".publish-", dir=destination) as tmp:
        staged = Path(tmp) / metadata["release"]
        staged.mkdir()
        for artifact in metadata["artifacts"].values():
            source = bundle / artifact["filename"]
            target = staged / artifact["filename"]
            shutil.copyfile(source, target)
            with target.open("rb") as file:
                digest = hashlib.file_digest(file, "sha256").hexdigest()
            if (
                digest != artifact["sha256"]
                or target.stat().st_size != artifact["size"]
            ):
                raise ValueError("Installer checksum/size mismatch")
        shutil.copyfile(manifest, staged / "update-manifest.json")
        target = destination / metadata["release"]
        if target.exists():
            if (target / "update-manifest.json").read_bytes() != manifest.read_bytes():
                raise ValueError("Refusing to overwrite a different release")
            for artifact in metadata["artifacts"].values():
                installed = target / artifact["filename"]
                with installed.open("rb") as file:
                    digest = hashlib.file_digest(file, "sha256").hexdigest()
                if (
                    installed.stat().st_size != artifact["size"]
                    or digest != artifact["sha256"]
                ):
                    raise ValueError(
                        "Existing published files are corrupt; inspect before replacing"
                    )
        else:
            staged.rename(target)
        latest = Path(tmp) / "latest.json"
        latest.write_text(json.dumps(envelope) + "\n")
        os.replace(latest, destination / "latest.json")
    print(f"Published client update {metadata['release']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    args = parser.parse_args()
    from app.core.config import settings

    publish(args.bundle, Path(settings.STORAGE_DIR) / "client-updates")
