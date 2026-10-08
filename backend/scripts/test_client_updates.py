"""Signed update publication and read-only download API, without a live DB."""

import base64
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "deploy"))
os.environ["DEBUG"] = "false"
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI
from fastapi.testclient import TestClient
from publish_client_update import prune, publish

from app.api.v1 import updates
from app.core import client_updates


class UpdateTests(unittest.TestCase):
    def test_signed_publish_download_tamper_and_traversal(self):
        key = Ed25519PrivateKey.generate()
        public = base64.b64encode(key.public_key().public_bytes_raw()).decode()
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.object(client_updates, "PUBLIC_KEY", public),
        ):
            root = Path(tmp)
            bundle, destination = root / "bundle", root / "published"
            bundle.mkdir()
            artifacts = {}
            for platform, name in [
                ("windows", "ddeck-setup-1.0.8.exe"),
                ("android", "ddeck-1.0.8-arm64.apk"),
            ]:
                contents = f"fake {platform} installer".encode()
                (bundle / name).write_bytes(contents)
                artifacts[platform] = {
                    "filename": name,
                    "size": len(contents),
                    "sha256": hashlib.sha256(contents).hexdigest(),
                }
            payload = json.dumps(
                {
                    "schema": 1,
                    "version": "1.0.8",
                    "build": 8,
                    "release": "1.0.8-8",
                    "artifacts": artifacts,
                }
            ).encode()
            envelope = {
                "payload": base64.b64encode(payload).decode(),
                "signature": base64.b64encode(key.sign(payload)).decode(),
            }
            (bundle / "update-manifest.json").write_text(json.dumps(envelope))
            app = FastAPI()
            app.include_router(updates.router)
            with (
                patch.object(updates, "update_root", return_value=destination),
                TestClient(app) as client,
            ):
                self.assertEqual(client.get("/updates/latest").status_code, 404)
                publish(bundle, destination)
                self.assertEqual(client.get("/updates/latest").json(), envelope)
                response = client.get("/updates/files/1.0.8-8/ddeck-setup-1.0.8.exe")
                self.assertEqual(response.content, b"fake windows installer")
                self.assertEqual(
                    client.get("/updates/files/1.0.8-8/.env").status_code, 404
                )
                self.assertEqual(
                    client.get(
                        "/updates/files/invalid/ddeck-setup-1.0.8.exe"
                    ).status_code,
                    404,
                )
                (bundle / "ddeck-setup-1.0.8.exe").write_bytes(b"corrupt")
                with self.assertRaises(ValueError):
                    publish(bundle, destination)
                # 새 버전을 게시하면 예전 버전 설치 파일 폴더는 지운다.
                (destination / "1.0.7-7").mkdir()
                (destination / "1.0.7-7" / "old.exe").write_bytes(b"old")
                (destination / "notes").mkdir()
                (bundle / "ddeck-setup-1.0.8.exe").write_bytes(
                    b"fake windows installer"
                )
                publish(bundle, destination)
                self.assertFalse((destination / "1.0.7-7").exists())
                self.assertTrue((destination / "1.0.8-8").is_dir())
                self.assertTrue((destination / "notes").is_dir())
                self.assertEqual(prune(destination), [])
                envelope["payload"] = base64.b64encode(b"{}").decode()
                (destination / "latest.json").write_text(json.dumps(envelope))
                self.assertEqual(client.get("/updates/latest").status_code, 503)

    def test_github_sync_publishes_verified_release_only(self):
        import httpx

        from app.services import client_update_sync as sync_module

        key = Ed25519PrivateKey.generate()
        public = base64.b64encode(key.public_key().public_bytes_raw()).decode()

        def release(version, build, tamper=False):
            files, artifacts = {}, {}
            for platform, name in [
                ("windows", f"ddeck-setup-{version}.exe"),
                ("android", f"ddeck-{version}-arm64.apk"),
            ]:
                body = f"{platform} {version}".encode()
                files[name] = body + (b"!" if tamper and platform == "android" else b"")
                artifacts[platform] = {
                    "filename": name,
                    "size": len(body),
                    "sha256": hashlib.sha256(body).hexdigest(),
                }
            payload = json.dumps(
                {
                    "schema": 1,
                    "version": version,
                    "build": build,
                    "release": f"{version}-{build}",
                    "artifacts": artifacts,
                }
            ).encode()
            files["update-manifest.json"] = json.dumps(
                {
                    "payload": base64.b64encode(payload).decode(),
                    "signature": base64.b64encode(key.sign(payload)).decode(),
                }
            ).encode()
            return files

        served = {}

        def github(request):
            if request.url.path.endswith("/releases/latest"):
                return httpx.Response(
                    200,
                    json={
                        "assets": [
                            {"name": n, "browser_download_url": f"https://dl/{n}"}
                            for n in served
                        ]
                    },
                )
            return httpx.Response(200, content=served[request.url.path.lstrip("/")])

        real_client = httpx.Client
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.object(client_updates, "PUBLIC_KEY", public),
            patch.object(sync_module.settings, "STORAGE_DIR", tmp),
            patch.object(
                sync_module.httpx,
                "Client",
                side_effect=lambda **kw: real_client(
                    transport=httpx.MockTransport(github), **kw
                ),
            ),
        ):
            published = Path(tmp) / "client-updates"
            served.update(release("1.0.9", 9))
            self.assertEqual(sync_module.sync()["status"], "published")
            self.assertTrue((published / "1.0.9-9" / "ddeck-1.0.9-arm64.apk").is_file())
            self.assertEqual(sync_module.sync()["status"], "up_to_date")
            served.clear()
            served.update(release("1.0.10", 10, tamper=True))
            with self.assertRaises(ValueError):
                sync_module.sync()
            latest = json.loads((published / "latest.json").read_text())
            self.assertEqual(
                client_updates.verify_manifest(latest)["release"], "1.0.9-9"
            )
            self.assertEqual(
                sorted(p.name for p in published.iterdir()), ["1.0.9-9", "latest.json"]
            )


if __name__ == "__main__":
    unittest.main()
