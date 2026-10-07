"""UI connection transactions, boundary checks and rclone continuation flow."""

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

TEMP = tempfile.TemporaryDirectory()
os.environ.update(DEBUG="false", BACKUP_ROOT=TEMP.name, SCHEDULER_ENABLED="false")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core.errors import AppError
from app.services import drive_setup as d


class SetupTest(unittest.TestCase):
    def setUp(self):
        self.ident = "a" * 32
        with d.backup.state() as s:
            s.clear()
            s.update(
                rclone_target="old:Backup",
                email="old",
                enabled=False,
                drive_setup={
                    "id": self.ident,
                    "remote": "ddeck_ui_" + self.ident,
                    "stage": "working",
                    "expires": time.time() + 1800,
                    "baseline": "old:Backup",
                },
            )

    def test_local_authenticated_console_boundary(self):
        def request(ip, headers=None):
            return SimpleNamespace(
                client=SimpleNamespace(host=ip), headers=headers or {}
            )

        self.assertTrue(d.local_console(request("127.0.0.1")))
        for req in (
            request("192.168.0.20"),
            request("127.0.0.1", {"origin": "http://localhost"}),
            request("127.0.0.1", {"x-forwarded-for": "127.0.0.1"}),
        ):
            with self.assertRaises(AppError):
                d.require_console(req)

    def test_shared_drive_choice_is_not_auto_answered(self):
        responses = [
            {"State": "local", "Option": {"Name": "config_is_local"}},
            {"State": "team", "Option": {"Name": "config_change_team_drive"}},
            {
                "State": "select",
                "Option": {
                    "Name": "config_team_drive",
                    "Exclusive": True,
                    "Examples": [{"Value": "drive123", "Help": "회사 공유 드라이브"}],
                },
            },
        ]
        with patch.object(d, "command", side_effect=responses) as command:
            d.work(self.ident, None)
        self.assertEqual(command.call_count, 3)
        data = d.get(self.ident)
        self.assertEqual(data["stage"], "question")
        self.assertEqual(data["option"]["Name"], "config_team_drive")
        self.assertNotIn("state", data)
        self.assertNotIn("remote", data)
        with patch.object(d.threading.Thread, "start"):
            with self.assertRaises(AppError):
                d.answer(self.ident, "unlisted-drive")
            d.answer(self.ident, "drive123")

    def make_ready(self):
        with d.backup.state() as s:
            s["drive_setup"]["stage"] = "ready"

    def test_finish_failure_preserves_old_account(self):
        self.make_ready()
        with (
            patch.object(
                d.rclone, "validate", side_effect=AppError("FAIL", "failed", 502)
            ),
            self.assertRaises(AppError),
        ):
            d.finish(self.ident, "Backup")
        with d.backup.state() as s:
            self.assertEqual(s["rclone_target"], "old:Backup")
            self.assertEqual(s["drive_setup"]["stage"], "ready")

    def test_save_and_cancel_preserve_applied_remote(self):
        self.make_ready()
        with patch.object(d.rclone, "validate", return_value="new"):
            result = d.finish(self.ident, "Backup")
        self.assertTrue(result["rclone_target"].startswith("ddeck_ui_"))
        with patch.object(d.rclone, "run") as command:
            with self.assertRaises(AppError):
                d.cancel(self.ident)
            command.assert_not_called()

    def test_cancel_only_new_remote(self):
        self.make_ready()
        with patch.object(d.rclone, "run") as command:
            d.cancel(self.ident)
            command.assert_called_once_with(
                "config", "delete", "ddeck_ui_" + self.ident
            )
        with d.backup.state() as s:
            self.assertEqual(s["rclone_target"], "old:Backup")

    def test_folder_traversal_rejected(self):
        for folder in ("../x", "/root", "remote:secret", "a/../b", "a\\b", "a\nb"):
            with self.assertRaises(AppError):
                d.folder_path(folder)

    def test_concurrent_account_change_not_overwritten(self):
        self.make_ready()
        with d.backup.state() as s:
            s["rclone_target"] = "other:Backup"
        with (
            patch.object(d.rclone, "validate", return_value="new"),
            self.assertRaises(AppError),
        ):
            d.finish(self.ident, "Backup")
        with d.backup.state() as s:
            self.assertEqual(s["rclone_target"], "other:Backup")

    def test_login_link_shown_while_waiting(self):
        url = "http://127.0.0.1:53682/auth?state=Ab_9-z"
        fake = Path(TEMP.name) / "rclone"
        fake.write_text(
            "#!/bin/sh\n"
            f"echo '<5>NOTICE: If your browser does not open go to: {url}' >&2\n"
            "sleep 2\n"
            'echo \'{"State": ""}\'\n'
        )
        fake.chmod(0o700)
        seen = []

        def watch():
            for _ in range(30):
                data = d.get(self.ident)
                if data["auth_url"]:
                    seen.append(data["auth_url"])
                    return
                time.sleep(0.1)

        watcher = d.threading.Thread(target=watch)
        with patch.object(d.shutil, "which", return_value=str(fake)):
            watcher.start()
            self.assertEqual(d.command(self.ident, ["config"]), {"State": ""})
            watcher.join()
        self.assertEqual(seen, [url])
        with d.backup.state() as s:
            s["drive_setup"]["stage"] = "ready"
        self.assertIsNone(d.get(self.ident)["auth_url"])


if __name__ == "__main__":
    unittest.main()
