"""The root power helper must accept only a sane request from the service account.

rtcwake and systemctl are replaced by recorders on PATH, so nothing is powered off.
"""
import getpass
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import power_helper


class PowerHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.log = root / "calls.log"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in ("rtcwake", "systemctl"):
            fake = bin_dir / name
            fake.write_text(f'#!/bin/bash\necho "{name} $*" >> "{self.log}"\n')
            fake.chmod(0o755)
        self.helper = root / "ddeck-power-off"
        self.helper.write_text(power_helper.render_helper(getpass.getuser()))
        self.helper.chmod(0o755)
        self.request = power_helper.request_path(root / "바탕 화면")
        self.request.parent.mkdir(parents=True)
        self.env = {**os.environ, "PATH": f"{bin_dir}:/usr/bin:/bin"}

    def tearDown(self):
        self.tmp.cleanup()

    def run_helper(self):
        return subprocess.run([str(self.helper), str(self.request)], env=self.env, capture_output=True, text=True, check=False)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_valid_request_arms_alarm_then_powers_off(self):
        wake = int(time.time()) + 3600
        self.request.write_text(str(wake))
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [f"rtcwake -m no -t {wake}", "systemctl poweroff"])
        self.assertFalse(self.request.exists(), "request must be consumed")

    def test_rejects_bad_requests_without_powering_off(self):
        now = int(time.time())
        for content in ("abc", "1; reboot", str(now + 60), str(now + 3 * 86400), ""):
            with self.subTest(content=content):
                self.request.write_text(content)
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.request.exists())

    def test_symlink_is_removed_not_followed(self):
        target = Path(self.tmp.name) / "secret"
        target.write_text(str(int(time.time()) + 3600))
        self.request.symlink_to(target)
        result = self.run_helper()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.request.is_symlink())
        self.assertTrue(target.exists())

    def test_request_from_another_account_is_refused(self):
        helper = power_helper.render_helper("someone_else")
        self.helper.write_text(helper)
        self.request.write_text(str(int(time.time()) + 3600))
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_units_escape_paths_and_reject_root(self):
        path_unit, service_unit = power_helper.render_units(Path("/home/op/바탕 화면/50%/$x/backups/.power/request"))
        self.assertIn("PathExists=/home/op/바탕 화면/50%%/$x/backups/.power/request", path_unit)
        self.assertIn("ExecStart=/usr/local/sbin/ddeck-power-off '/home/op/바탕 화면/50%%/$$x/backups/.power/request'", service_unit)
        self.assertIn("Type=oneshot", service_unit)
        for user in ("root", "x\nExecStart=/bad"):
            with self.assertRaises(ValueError):
                power_helper.render_helper(user)
        with self.assertRaises(ValueError):
            power_helper.render_units(Path("/a'b/request"))


if __name__ == "__main__":
    unittest.main()
