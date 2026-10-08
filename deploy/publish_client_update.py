"""Atomically publish verified installers downloaded from a private GitHub release."""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = re.compile(r"\d+\.\d+\.\d+-\d+")
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
    prune(destination)


def prune(destination: Path) -> list[str]:
    """게시된 최신 버전만 남기고 예전 설치 파일 폴더를 지운다.

    기기는 latest.json 의 버전만 받는다. 예전 설치 파일은 GitHub 릴리즈에 남아 있다.
    latest.json 을 바꾼 뒤에 지우므로, 받는 중이던 기기는 다음 확인 때 새 버전을 받는다.
    """
    current = verify_manifest(json.loads((destination / "latest.json").read_text()))
    removed = []
    for folder in destination.iterdir():
        if (
            folder.is_dir()
            and not folder.is_symlink()
            and RELEASE.fullmatch(folder.name)
            and folder.name != current["release"]
        ):
            shutil.rmtree(folder)
            removed.append(folder.name)
    if removed:
        print("Removed previous installers: " + ", ".join(sorted(removed)))
    return removed


if __name__ == "__main__":
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
