"""Service registration must preserve existing services, data and virtualenv paths."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_service_schema as schema
import register_systemd as service


class RegistrationTests(unittest.TestCase):
    def test_literal_paths_and_single_worker(self):
        root = Path('/home/operator/바탕 화면/test%name/$data')
        python = root / 'backend/.venv-linux/bin/python'
        content = service.render(root, python, 'operator', 8000)
        self.assertIn('WorkingDirectory=/home/operator/바탕 화면/test%%name/$data/backend', content)
        self.assertIn('test%%name/$$data/backend/.venv-linux/bin/python" -m uvicorn', content)
        self.assertIn('--workers 1', content)
        self.assertIn('ExecCondition=', content)
        self.assertNotIn('upgrade head', content)
        self.assertNotIn('EnvironmentFile=', content)

    def test_reject_invalid_inputs(self):
        for user, port in [('root', 8000), ('x\nExecStart=/bad', 8000), ('worker', 0), ('worker', 65536)]:
            with self.assertRaises(ValueError):
                service.render(Path('/app'), Path('/python'), user, port)
        with self.assertRaises(ValueError):
            service.quote('/path\n[Service]')

    def test_install_registers_without_start_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(service.subprocess, 'run') as run:
            unit = Path(tmp) / 'ddeck.service'
            content = service.render(Path('/app'), Path('/venv/bin/python'), 'worker', 8000)
            service.install(content, unit)
            self.assertEqual(unit.read_text(), content)
            self.assertEqual(unit.stat().st_mode & 0o777, 0o644)
            service.install(content, unit)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual([cmd for cmd in commands if cmd[0] == 'systemctl'], [['systemctl', 'daemon-reload']] * 2)

    def test_existing_or_masked_service_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(service.subprocess, 'run') as run:
            unit = Path(tmp) / 'ddeck.service'
            unit.write_text('existing service')
            with self.assertRaises(ValueError):
                service.install('replacement', unit)
            self.assertEqual(unit.read_text(), 'existing service')
            unit.unlink()
            unit.symlink_to('/dev/null')
            with self.assertRaises(ValueError):
                service.install('replacement', unit)
            run.assert_not_called()

    def test_schema_failure_codes_never_trigger_restart(self):
        for code in (1, 255, -15):
            with patch.object(schema.subprocess, 'run') as run:
                run.return_value.returncode = code
                self.assertEqual(schema.main(), 1)
        with patch.object(schema.subprocess, 'run') as run:
            run.return_value.returncode = 0
            self.assertEqual(schema.main(), 0)

    def test_exact_legacy_unit_upgrade_keeps_backup(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(service.subprocess, 'run') as run:
            unit = Path(tmp) / 'ddeck.service'
            unit.write_text('exact legacy')
            service.install('corrected', unit, legacy_content='exact legacy')
            self.assertEqual(unit.read_text(), 'corrected')
            self.assertEqual(unit.with_name(unit.name + '.before-schema-check-fix').read_text(), 'exact legacy')
            self.assertEqual(run.call_args.args[0], ['systemctl', 'daemon-reload'])

    def test_invalid_unit_not_installed(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(service.subprocess, 'run', side_effect=service.subprocess.CalledProcessError(1, 'verify')):
            unit = Path(tmp) / 'ddeck.service'
            with self.assertRaises(service.subprocess.CalledProcessError):
                service.install('invalid', unit)
            self.assertFalse(unit.exists())


if __name__ == '__main__':
    unittest.main()
