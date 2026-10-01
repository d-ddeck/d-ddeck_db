"""First-time HTTPS activation for an existing manual Ubuntu server.

Preview by default. Requires sudo for --apply; refuses existing managed files.
Google safety backup and schema checks complete before the manual server stops.
"""
import argparse
import ipaddress
import os
import pwd
import signal
import ssl
import subprocess
import time
import urllib.request
from pathlib import Path

from configure_https import render as nginx_config
from register_systemd import render as service_config


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", required=True)
    parser.add_argument("--lan", required=True)
    parser.add_argument("--vpn", required=True)
    parser.add_argument("--cert-dir", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    ipaddress.ip_address(args.ip)
    root = args.root.resolve()
    backend = root / "backend"
    owner = pwd.getpwuid(backend.stat().st_uid)
    python = backend / ".venv/bin/python"
    unit = Path("/etc/systemd/system/ddeck.service")
    conf = Path("/etc/nginx/conf.d/ddeck.conf")
    tls = Path("/etc/ddeck/tls")
    cert, key = args.cert_dir / "server.crt", args.cert_dir / "server.key"
    ca = root / "deploy/trust/company_ca.crt"
    content = nginx_config(args.ip, [args.lan, args.vpn], tls / "server.crt", tls / "server.key", 8000)
    service = service_config(root, python, owner.pw_name, 8000).replace(
        "--host 0.0.0.0", "--host 127.0.0.1"
    ).replace("Environment=PYTHONUNBUFFERED=1", "Environment=PYTHONUNBUFFERED=1\nEnvironment=DEBUG=false\nEnvironment=TRUSTED_PROXY_IPS=127.0.0.1/32")
    run("openssl", "verify", "-CAfile", str(ca), "-verify_ip", args.ip, str(cert))
    run("openssl", "x509", "-in", str(cert), "-noout", "-checkend", "604800")
    check = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    check.load_cert_chain(cert, key)  # Includes private-key/certificate match.
    if key.stat().st_mode & 0o077:
        parser.error("Private key must have mode 0600")
    if not args.apply:
        print(content)
        print(service)
        print("Preview only: backup, service transition and TLS validation require --apply with sudo.")
        return
    if os.geteuid() != 0:
        parser.error("sudo is required for --apply")
    if any(p.exists() or p.is_symlink() for p in (unit, conf, tls, Path(str(unit) + '.d'))):
        parser.error("Existing HTTPS/service configuration found; review instead of overwriting")
    pid = int((backend / "server.pid").read_text().strip())
    proc = Path(f"/proc/{pid}")
    original = [part.decode() for part in (proc / "cmdline").read_bytes().split(b"\0") if part]
    if (proc / "cwd").resolve() != backend or "app.main:app" not in original or "uvicorn" not in original:
        parser.error("server.pid does not identify this checkout's manual uvicorn")
    os.chdir(backend)
    run("systemctl", "is-active", "--quiet", "nginx")
    run("runuser", "-u", owner.pw_name, "--", "env", "DEBUG=false", str(python), str(root / "deploy/check_service_schema.py"))
    run("runuser", "-u", owner.pw_name, "--", "env", "DEBUG=false", str(python), str(root / "deploy/cloud_backup.py"))
    stopped = False
    try:
        tls.mkdir(parents=True, mode=0o700)
        for source, target, mode in [(cert, tls / "server.crt", 0o644), (key, tls / "server.key", 0o600)]:
            target.write_bytes(source.read_bytes())
            target.chmod(mode)
        conf.write_text(content)
        unit.write_text(service)
        run("nginx", "-t")
        run("systemd-analyze", "verify", str(unit))
        run("systemctl", "daemon-reload")
        # All prerequisites succeeded; now replace the manual process.
        os.kill(pid, signal.SIGTERM)
        stopped = True
        for _ in range(100):
            if not proc.exists() or (proc / "stat").read_text().split(") ")[1].startswith("Z"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Manual server did not stop")
        run("systemctl", "start", "ddeck")
        run("systemctl", "reload", "nginx")
        context = ssl.create_default_context(cafile=str(ca))
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
        for _ in range(30):
            try:
                with opener.open(f"https://{args.ip}/healthz", timeout=2) as response:
                    if response.status == 200:
                        break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.5)
        else:
            raise RuntimeError("HTTPS health check failed")
        new_pid = run("systemctl", "show", "ddeck", "--property=MainPID", "--value").stdout.strip()
        (backend / "server.pid").write_text(new_pid)
        run("systemctl", "enable", "ddeck")
        print("HTTPS verified; backend is loopback-only. Test LAN and VPN clients before distributing the new app.")
    except Exception:
        subprocess.run(["systemctl", "stop", "ddeck"], check=False, capture_output=True)
        conf.unlink(missing_ok=True)
        unit.unlink(missing_ok=True)
        for path in tls.glob("*"):
            path.unlink()
        if tls.exists():
            tls.rmdir()
        subprocess.run(["systemctl", "daemon-reload"], check=False, capture_output=True)
        subprocess.run(["systemctl", "reload", "nginx"], check=False, capture_output=True)
        if stopped and (not proc.exists() or (proc / "stat").read_text().split(") ")[1].startswith("Z")):
            env = {**os.environ, "DEBUG": "false", "HOME": owner.pw_dir}
            with (backend / "server.log").open("ab") as log:
                process = subprocess.Popen(original, cwd=backend, env=env, stdout=log, stderr=log,
                                           start_new_session=True, user=owner.pw_uid, group=owner.pw_gid,
                                           extra_groups=os.getgrouplist(owner.pw_name, owner.pw_gid))
            (backend / "server.pid").write_text(str(process.pid))
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - never print backup transport credentials
        raise SystemExit("HTTPS activation failed. Existing manual server was preserved or restart attempted; inspect server status. No private credentials were printed.") from None
