"""Retention safety without contacting Google or deleting real files."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ["DEBUG"] = "false"
from app.core.errors import AppError
from app.services import rclone_backup as r


class BackupTest(unittest.TestCase):
    def archive(self, n):
        return f"drive_20260929_030000_{n:06d}.zip"

    def execute(self, count=33, failure=None, duplicate=False):
        calls = []

        def fake(*args, **kwargs):
            calls.append(args)
            if args[0] == failure:
                raise AppError("TEST", "test", 502)
            if args[0] == "config":
                return "[gdrive]\ntype = drive\nteam_drive = XXX\n"
            if "--stat" in args:
                return '{"IsDir":true}'
            if args[0] == "lsjson":
                names = [self.archive(i) for i in range(count)]
                if duplicate:
                    names.append(names[0])
                entries = [{"Name": n, "Path": n, "IsDir": False} for n in names]
                entries += [
                    {"Name": "notes.txt", "Path": "notes.txt", "IsDir": False},
                    {
                        "Name": self.archive(99),
                        "Path": "sub/" + self.archive(99),
                        "IsDir": False,
                    },
                    {
                        "Name": "20260928_003001",
                        "Path": "20260928_003001",
                        "IsDir": True,
                    },
                ]
                return json.dumps(entries)
            return ""

        with patch.object(r, "run", side_effect=fake):
            if failure or duplicate:
                with self.assertRaises(AppError):
                    r.upload("gdrive:Backup", Path("/tmp") / self.archive(count - 1))
            else:
                r.upload("gdrive:Backup", Path("/tmp") / self.archive(count - 1))
        return calls

    def test_keep_thirty_oldest_first(self):
        calls = self.execute()
        deleted = [a[1] for a in calls if a[0] == "deletefile"]
        self.assertEqual(
            deleted, ["gdrive:Backup/" + self.archive(i) for i in range(3)]
        )
        self.assertLess(
            next(i for i, a in enumerate(calls) if a[0] == "check"),
            next(i for i, a in enumerate(calls) if a[0] == "deletefile"),
        )

    def test_at_limit_no_delete(self):
        self.assertFalse(any(a[0] == "deletefile" for a in self.execute(30)))

    def test_failure_never_prunes(self):
        for stage in ("copyto", "check"):
            self.assertFalse(
                any(a[0] == "deletefile" for a in self.execute(failure=stage))
            )

    def test_duplicate_never_prunes(self):
        self.assertFalse(
            any(a[0] == "deletefile" for a in self.execute(duplicate=True))
        )

    def test_target_injection(self):
        with patch.object(r, "run") as command:
            for target in (
                "/tmp",
                ":drive:path",
                "gdrive:",
                "gdrive:../x",
                "gdrive,opt=x:foo",
                "gdrive:/foo",
                "gdrive:foo\nbar",
            ):
                with self.assertRaises(AppError):
                    r.validate(target)
            command.assert_not_called()

    def test_requires_shared_drive_folder(self):
        with (
            patch.object(
                r, "run", return_value="[gdrive]\ntype = drive\nteam_drive =\n"
            ),
            self.assertRaises(AppError),
        ):
            r.validate("gdrive:Backup")
        with (
            patch.object(
                r,
                "run",
                side_effect=[
                    "[gdrive]\ntype = drive\nteam_drive = XXX\n",
                    '{"IsDir":false}',
                ],
            ),
            self.assertRaises(AppError),
        ):
            r.validate("gdrive:Backup")

    def test_upload_progress_from_json_stats(self):
        with tempfile.TemporaryDirectory() as folder:
            fake = Path(folder) / "rclone"
            lines = [
                {"stats": {"bytes": 0, "totalBytes": 0}},
                {"stats": {"bytes": 250, "totalBytes": 1000}},
                {"level": "info", "msg": "no stats here"},
                {"stats": {"bytes": 1000, "totalBytes": 1000}},
            ]
            fake.write_text(
                "#!/bin/sh\n"
                + "".join(f"echo '{json.dumps(line)}' >&2\n" for line in lines)
                + "echo 'not json' >&2\n"
            )
            fake.chmod(0o700)
            seen = []
            with patch.object(r.shutil, "which", return_value=str(fake)):
                r.run_with_progress("copyto", "a", "b", on_progress=seen.append)
            self.assertEqual(seen, [25.0, 100.0])
            fake.write_text("#!/bin/sh\nexit 3\n")
            with (
                patch.object(r.shutil, "which", return_value=str(fake)),
                self.assertRaises(AppError),
            ):
                r.run_with_progress("copyto", "a", "b", on_progress=seen.append)


if __name__ == "__main__":
    unittest.main()
