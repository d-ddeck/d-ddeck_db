"""Publish new client installers from the latest GitHub release on its own.

Before this, a person had to download the release and run the publish command,
so devices kept seeing an old version. The server now checks the public
repository on a schedule. The release manifest is Ed25519-signed and every
installer is size/SHA-256 checked by publish(), so a tampered download is never
served. Older releases are refused and old installers are pruned.
"""

from __future__ import annotations

import json
import logging
import tempfile
import threading
from pathlib import Path

import httpx

from app.core.client_updates import publish, release_key, verify_manifest
from app.core.config import settings

log = logging.getLogger(__name__)
API = "https://api.github.com/repos/{repo}/releases/latest"
_lock = threading.Lock()


def _destination() -> Path:
    return Path(settings.STORAGE_DIR) / "client-updates"


def _current() -> dict | None:
    try:
        return verify_manifest(json.loads((_destination() / "latest.json").read_text()))
    except (OSError, ValueError, KeyError):
        return None


def sync() -> dict:
    """Check GitHub once. Returns {"status": ..., "release": ...} for logs and the API."""
    repo = settings.CLIENT_UPDATE_REPO.strip()
    if not repo:
        return {"status": "disabled", "release": None}
    if not _lock.acquire(blocking=False):
        return {"status": "busy", "release": None}
    try:
        with httpx.Client(timeout=30, follow_redirects=True) as client:
            release = client.get(
                API.format(repo=repo), headers={"Accept": "application/vnd.github+json"}
            )
            release.raise_for_status()
            assets = {
                a["name"]: a["browser_download_url"] for a in release.json()["assets"]
            }
            if "update-manifest.json" not in assets:
                return {"status": "no_manifest", "release": None}
            manifest = client.get(assets["update-manifest.json"])
            manifest.raise_for_status()
            if len(manifest.content) > 65536:
                raise ValueError("Oversized manifest")
            envelope = manifest.json()
            metadata = verify_manifest(envelope)
            current = _current()
            if current and release_key(metadata) <= release_key(current):
                return {"status": "up_to_date", "release": current["release"]}
            destination = _destination()
            destination.mkdir(parents=True, exist_ok=True)
            # Same filesystem as the published folder, so publish() can rename.
            with tempfile.TemporaryDirectory(
                prefix=".download-", dir=destination
            ) as tmp:
                bundle = Path(tmp)
                (bundle / "update-manifest.json").write_bytes(manifest.content)
                for artifact in metadata["artifacts"].values():
                    name = artifact["filename"]
                    if name not in assets:
                        raise ValueError(f"Release asset missing: {name}")
                    _download(client, assets[name], bundle / name, artifact["size"])
                published = publish(bundle, destination)
            log.info("client update %s published from GitHub", published)
            return {"status": "published", "release": published}
    finally:
        _lock.release()


def _download(client: httpx.Client, url: str, target: Path, size: int) -> None:
    written = 0
    with client.stream("GET", url, timeout=600) as response, target.open("wb") as out:
        response.raise_for_status()
        for chunk in response.iter_bytes(1024 * 1024):
            written += len(chunk)
            if written > size:
                raise ValueError(f"Download larger than the manifest: {target.name}")
            out.write(chunk)


def scheduled() -> None:
    try:
        result = sync()
        if result["status"] not in ("up_to_date", "disabled"):
            log.info("client update sync: %s", result)
    except (httpx.HTTPError, OSError, ValueError, KeyError) as exc:
        log.warning("client update sync failed: %s: %s", type(exc).__name__, exc)
