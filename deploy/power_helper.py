"""Install the root helper that powers the server PC off after a scheduled backup.

The server runs as an unprivileged account with NoNewPrivileges, so it cannot
shut the machine down itself. It only writes a request file holding the wake
time (UNIX seconds). A root systemd path unit notices that file and runs a
helper installed outside the checkout (the service account must not be able to
edit code that runs as root). The helper validates the request, arms the RTC
wake alarm with rtcwake and powers off.

    python3 deploy/power_helper.py                 # preview
    sudo python3 deploy/power_helper.py --install  # install and enable
    sudo python3 deploy/power_helper.py --uninstall
"""

import argparse
import os
import pwd
import re
import subprocess
from pathlib import Path

MARKER = "# Managed by ddeck power_helper.py\n"
HELPER = Path("/usr/local/sbin/ddeck-power-off")
PATH_UNIT = Path("/etc/systemd/system/ddeck-power.path")
SERVICE_UNIT = Path("/etc/systemd/system/ddeck-power.service")

# Wake must land after the shutdown finishes and within two days.
MIN_LEAD_SECONDS = 300
MAX_LEAD_SECONDS = 172800


def request_path(root):
    """Where the server writes the request; mirrors drive_backup.power_request()."""
    return Path(root) / "backups" / ".power" / "request"


def _literal(value, *, command=False):
    """Escape a path for a unit file; Exec lines also expand dollars."""
    value = str(value)
    if any(ord(c) < 32 or ord(c) == 127 for c in value) or "'" in value or "\\" in value:
        raise ValueError("Unsupported characters in path")
    value = value.replace("%", "%%")
    return value.replace("$", "$$") if command else value


def render_helper(user):
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]*", user) or user == "root":
        raise ValueError("Use the non-root account that runs ddeck")
    return f"""#!/bin/bash
{MARKER.strip()}
# Arms the RTC wake alarm from a ddeck request, then powers the PC off.
set -euo pipefail
request="$1"
expected_user='{user}'
# A symlink could point root at another file; only a plain file owned by the
# service account is accepted, and it is consumed before anything else.
if [[ -L "$request" || ! -f "$request" ]]; then
  rm -f -- "$request"
  exit 0
fi
owner=$(stat -c %U -- "$request")
wake=$(head -c 32 -- "$request" | tr -d '[:space:]')
rm -f -- "$request"
if [[ "$owner" != "$expected_user" ]]; then
  echo "ddeck-power: request not owned by $expected_user" >&2
  exit 1
fi
if [[ ! "$wake" =~ ^[0-9]{{10}}$ ]]; then
  echo "ddeck-power: invalid wake time" >&2
  exit 1
fi
now=$(date +%s)
if (( wake < now + {MIN_LEAD_SECONDS} || wake > now + {MAX_LEAD_SECONDS} )); then
  echo "ddeck-power: wake time out of range" >&2
  exit 1
fi
echo "ddeck-power: wake alarm $(date -d "@$wake" '+%F %T %Z'), powering off"
rtcwake -m no -t "$wake"
systemctl poweroff
"""


def render_units(request):
    path_unit = MARKER + f"""[Unit]
Description=d-ddeck power-off request after backup

[Path]
PathExists={_literal(request)}
Unit=ddeck-power.service

[Install]
WantedBy=multi-user.target
"""
    service_unit = MARKER + f"""[Unit]
Description=d-ddeck power off and schedule wake-up

[Service]
Type=oneshot
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
ExecStart={HELPER} '{_literal(request, command=True)}'
"""
    return path_unit, service_unit


def _write(path, content, mode):
    if path.is_symlink():
        raise ValueError(f"Refusing to replace symlink {path}")
    if path.exists() and not path.read_text(encoding="utf-8").startswith(
        ("#!/bin/bash\n" + MARKER) if path == HELPER else MARKER
    ):
        raise ValueError(f"{path} exists and is not managed by ddeck")
    staged = path.with_name(f".{path.name}.tmp")
    staged.write_text(content, encoding="utf-8")
    staged.chmod(mode)
    os.chown(staged, 0, 0)
    staged.replace(path)


def install(user, request):
    helper = render_helper(user)
    path_unit, service_unit = render_units(request)
    # The request folder is the server's; the root helper only reads from it.
    folder = Path(request).parent
    account = pwd.getpwnam(user)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chown(folder, account.pw_uid, account.pw_gid)
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    _write(HELPER, helper, 0o755)
    _write(SERVICE_UNIT, service_unit, 0o644)
    _write(PATH_UNIT, path_unit, 0o644)
    subprocess.run(["systemd-analyze", "verify", str(PATH_UNIT)], check=True)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", PATH_UNIT.name], check=True)


def uninstall():
    subprocess.run(["systemctl", "disable", "--now", PATH_UNIT.name], check=False)
    for path in (PATH_UNIT, SERVICE_UNIT, HELPER):
        if path.exists() and not path.is_symlink():
            path.unlink()
    subprocess.run(["systemctl", "daemon-reload"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="backup root (BACKUP_ROOT)")
    parser.add_argument("--user", default=os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--install", action="store_true")
    action.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    request = request_path(args.root.resolve())
    try:
        if args.install or args.uninstall:
            if os.geteuid() != 0:
                parser.error("Installation requires sudo; preview works without sudo")
            if args.install:
                pwd.getpwnam(args.user)
                install(args.user, request)
                print(f"Installed. Requests are read from {request}")
                print("Test once from the app before relying on it: the BIOS must allow RTC wake from power-off.")
            else:
                uninstall()
                print("Removed the ddeck power helper.")
        else:
            path_unit, service_unit = render_units(request)
            print(f"# {HELPER}\n{render_helper(args.user)}\n# {PATH_UNIT}\n{path_unit}\n# {SERVICE_UNIT}\n{service_unit}", end="")
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Power helper setup failed: {error}\n")


if __name__ == "__main__":
    main()
