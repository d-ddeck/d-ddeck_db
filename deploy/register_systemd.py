"""Register an existing checkout without relocating data or starting its server."""

import argparse
import os
import pwd
import re
import subprocess
import tempfile
from pathlib import Path

MARKER = "# Managed by ddeck register_systemd.py\n"
UNIT = Path("/etc/systemd/system/ddeck.service")


def quote(value, *, command=False):
    """Escape a literal systemd argument (Exec directives also expand dollars)."""
    value = str(value)
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("Paths must not contain control characters")
    value = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    if command:
        value = value.replace("$", "$$")
    return '"' + value + '"'


def directory(path):
    # WorkingDirectory is a single path, not an Exec-style argument list.
    value = str(path)
    if any(ord(c) < 32 or ord(c) == 127 for c in value) or value != value.strip() or "\\" in value:
        raise ValueError("Unsupported working directory characters")
    return value.replace("%", "%%")


def render(root, python, user, port):
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]*\$?", user) or user == "root":
        raise ValueError("Use the non-root account that owns the existing installation")
    if not 1 <= port <= 65535:
        raise ValueError("Port must be between 1 and 65535")
    backend = root / "backend"
    executable = quote(python, command=True)
    return MARKER + f"""[Unit]
Description=d-ddeck DB Server (existing checkout)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User={user}
WorkingDirectory={directory(backend)}
# The application loads backend/.env; it is not a systemd EnvironmentFile.
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
# An incompatible DB skips startup. Never migrate automatically on restart.
ExecCondition={executable} {quote(root / "deploy/check_service_schema.py", command=True)}
# One worker: the notification scheduler runs inside the application.
ExecStart={executable} -m uvicorn app.main:app --host 0.0.0.0 --port {port} --workers 1 --no-access-log --no-proxy-headers
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
# Existing installations may keep their code, SQLite DB and uploads in /home.
ProtectHome=false
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ddeck

[Install]
WantedBy=multi-user.target
"""


def install(content, unit=UNIT, *, legacy_content=None):
    if unit.is_symlink():
        raise ValueError("Refusing to replace a symlink or masked service")
    if unit.exists():
        previous = unit.read_text(encoding="utf-8")
        if previous == content:
            subprocess.run(["systemctl", "daemon-reload"], check=True)
            return
        if legacy_content is None or previous != legacy_content:
            raise ValueError("An existing ddeck.service differs; inspect it before changing registration")
    # Validate before placing the unit. Never enable/start/stop an existing process.
    with tempfile.TemporaryDirectory(prefix="ddeck-systemd-") as directory:
        candidate = Path(directory) / "ddeck.service"
        candidate.write_text(content, encoding="utf-8")
        subprocess.run(["systemd-analyze", "verify", str(candidate)], check=True)
        if unit.exists():
            # Only the exact old generated unit can be upgraded; preserve custom units.
            if unit.is_symlink() or unit.read_text(encoding="utf-8") != legacy_content:
                raise ValueError("Service changed during registration")
            backup = unit.with_name(unit.name + ".before-schema-check-fix")
            with backup.open("x", encoding="utf-8") as output:
                output.write(legacy_content)
            backup.chmod(0o644)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=unit.parent, delete=False) as output:
                staged = Path(output.name)
                output.write(content)
            try:
                staged.chmod(0o644)
                staged.replace(unit)
            finally:
                staged.unlink(missing_ok=True)
        else:
            with unit.open("x", encoding="utf-8") as output:
                output.write(content)
            unit.chmod(0o644)
    subprocess.run(["systemctl", "daemon-reload"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--venv", type=Path, help="Absolute or backend-relative virtualenv path")
    parser.add_argument("--user", default=os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--install", action="store_true", help="Register only; no start or boot enablement")
    args = parser.parse_args()
    root = args.root.resolve()
    backend = root / "backend"
    venv = args.venv
    if venv is None:
        candidates = [backend / name for name in (".venv-linux", ".venv") if (backend / name / "bin/python").is_file()]
        if len(candidates) != 1:
            parser.error("Specify --venv: expected exactly one .venv-linux or .venv")
        venv = candidates[0]
    elif not venv.is_absolute():
        venv = backend / venv
    # Do not resolve bin/python: following its symlink loses the virtualenv.
    python = venv.absolute() / "bin/python"
    for path in (backend / "app/main.py", backend / "alembic.ini", backend / ".env", root / "deploy/check_service_schema.py", python):
        if not path.is_file():
            parser.error(f"Missing required file: {path}")
    if not os.access(python, os.X_OK):
        parser.error("Virtualenv Python is not executable")
    try:
        pwd.getpwnam(args.user)
        content = render(root, python, args.user, args.port)
        if args.install:
            if os.geteuid() != 0:
                parser.error("Registration requires sudo; preview works without sudo")
            legacy = content.replace(
                f'ExecCondition={quote(python, command=True)} {quote(root / "deploy/check_service_schema.py", command=True)}',
                f'ExecCondition={quote(python, command=True)} -m alembic check',
            )
            install(content, legacy_content=legacy)
            print("Registered ddeck.service. Existing server and DB were not changed.")
            print("After DB verification and stopping the manual server: sudo systemctl enable --now ddeck")
        else:
            print(content, end="")
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Registration failed: {error}\n")


if __name__ == "__main__":
    main()
