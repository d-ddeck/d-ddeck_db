"""Signed release metadata shared by the download API and deployment tooling."""

import base64
import hashlib
import json
import logging
import os
import re
import shutil
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

log = logging.getLogger(__name__)
RELEASE = re.compile(r"\d+\.\d+\.\d+-\d+")
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


def release_key(data: dict) -> tuple:
    return (*map(int, data["version"].split(".")), data["build"])


def publish(bundle: Path, destination: Path) -> str:
    """Verify a downloaded release bundle and publish it atomically.

    Signature, sizes and checksums are checked before latest.json changes, and an
    older release is refused. Returns the published release directory name.
    """
    manifest = bundle / "update-manifest.json"
    envelope = json.loads(manifest.read_text())
    metadata = verify_manifest(envelope)
    destination.mkdir(parents=True, exist_ok=True)
    latest_path = destination / "latest.json"
    if latest_path.exists():
        current = verify_manifest(json.loads(latest_path.read_text()))

        if release_key(metadata) < release_key(current):
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
    log.info("Published client update %s", metadata["release"])
    prune(destination)
    return metadata["release"]


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
        log.info("Removed previous installers: %s", ", ".join(sorted(removed)))
    return removed
