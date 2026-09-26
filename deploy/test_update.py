"""Exercise update.sh control flow with fake system services in an isolated tree.

Only the test copy has its root check removed and /opt/ddeck path replaced.
No installed service, application directory or real sudo command is used.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

DEPLOY = Path(__file__).resolve().parent


class UpdateTests(unittest.TestCase):
    def run_update(self, mode):
        with tempfile.TemporaryDirectory(prefix="ddeck-update-") as tmp:
            root = Path(tmp)
            target = root / "installed"
            source = root / "source"
            scripts = source / "deploy"
            fake_bin = root / "bin"
            for directory in [
                target / "backend/.venv/bin",
                scripts,
                source / "backend/app",
                fake_bin,
            ]:
                directory.mkdir(parents=True)
            trace = root / "trace"
            text = (
                (DEPLOY / "update.sh")
                .read_text()
                .replace('APP_DIR="/opt/ddeck"', f'APP_DIR="{target}"')
            )
            unit = root / "ddeck.service"
            unit.write_text(
                "ExecStart=/opt/ddeck/backend/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000\n"
            )
            text = text.replace("/etc/systemd/system/${SERVICE}.service", str(unit))
            text = "\n".join(
                line
                for line in text.splitlines()
                if not line.startswith("[[ $EUID -eq 0 ]]")
            )
            (scripts / "update.sh").write_text(text)
            if mode != "missing_backup":
                (scripts / "backup.sh").write_text(
                    'echo backup >> "$TRACE"\n[[ "$MODE" != backup_failure ]]\n'
                )

            def executable(path, contents):
                path.write_text("#!/bin/bash\n" + contents)
                path.chmod(0o755)

            for name in ["systemctl", "rsync", "chown", "chmod", "curl"]:
                executable(fake_bin / name, f'echo "{name} $*" >> "$TRACE"\nexit 0\n')
            executable(fake_bin / "sudo", 'shift 2\nexec "$@"\n')
            executable(
                target / "backend/.venv/bin/python",
                """
echo "python $*" >> "$TRACE"
[[ "$1" == scripts/adopt_schema.py ]] && exit 1
if [[ "$MODE" == migration_failure && "$*" == '-m alembic upgrade head' ]]; then exit 17; fi
exit 0
""",
            )
            result = subprocess.run(
                ["bash", str(scripts / "update.sh")],
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "PATH": str(fake_bin) + ":" + os.environ["PATH"],
                    "TRACE": str(trace),
                    "MODE": mode,
                },
                check=False,
            )
            if mode == "success":
                self.assertIn("harden_service.py", trace.read_text())
            return result, trace.read_text() if trace.exists() else ""

    def test_existing_install_routes_to_update_before_port_check(self):
        with tempfile.TemporaryDirectory(prefix="ddeck-reinstall-") as tmp:
            root = Path(tmp)
            scripts = root / "source/deploy"
            scripts.mkdir(parents=True)
            (root / "source/backend/app").mkdir(parents=True)
            installed = root / "installed"
            (installed / "backend").mkdir(parents=True)
            (installed / "backend/.env").touch()
            unit = root / "ddeck.service"
            unit.touch()
            text = (DEPLOY / "install.sh").read_text()
            text = (
                text.split(
                    "# ------------------------------------------------------------------ Python"
                )[0]
                + "\nexit 99\n"
            )
            text = text.replace('APP_DIR="/opt/${APP_NAME}"', f'APP_DIR="{installed}"')
            text = text.replace("/etc/systemd/system/${SERVICE}.service", str(unit))
            text = "\n".join(
                line
                for line in text.splitlines()
                if not line.startswith("[[ $EUID -eq 0 ]]")
            )
            (scripts / "install.sh").write_text(text)
            (scripts / "update.sh").write_text("echo UPGRADE_SELECTED\nexit 0\n")
            result = subprocess.run(
                ["bash", str(scripts / "install.sh")],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("UPGRADE_SELECTED", result.stdout)

    def test_backup_failure_restarts_old_service_without_copy(self):
        result, trace = self.run_update("backup_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("systemctl stop ddeck", trace)
        self.assertIn("systemctl start ddeck", trace)
        self.assertNotIn("rsync", trace)

    def test_missing_backup_stops_before_service_changes(self):
        result, trace = self.run_update("missing_backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("systemctl", trace)

    def test_migration_failure_does_not_start_mixed_version(self):
        result, trace = self.run_update("migration_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("alembic upgrade head", trace)
        self.assertNotIn("systemctl start", trace)
        self.assertIn("중지 상태로 유지", result.stderr)

    def test_success_stops_then_backs_up_then_replaces_then_starts(self):
        result, trace = self.run_update("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(trace.index("systemctl stop"), trace.index("backup"))
        self.assertLess(trace.index("backup"), trace.index("rsync"))
        self.assertLess(trace.index("alembic check"), trace.index("systemctl start"))
        self.assertIn("/deploy/", trace)
        self.assertIn("systemctl daemon-reload", trace)


if __name__ == "__main__":
    unittest.main()
