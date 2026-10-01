"""Create a private company CA and issue IP SAN server certificates offline."""
import argparse
import ipaddress
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def write_new(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def key_bytes(key):
    return key.private_bytes(serialization.Encoding.PEM,
                             serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


def create_ca(folder):
    folder = Path(folder)
    if (folder / "ca.key").exists() or (folder / "ca.crt").exists():
        raise ValueError("CA already exists; never overwrite a deployed trust root")
    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "D.DDECK Internal Root CA")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=3650))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True,
                                         False, False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False)
            .sign(key, hashes.SHA256()))
    write_new(folder / "ca.key", key_bytes(key))
    write_new(folder / "ca.crt", cert.public_bytes(serialization.Encoding.PEM))
    return cert


def issue(ca_folder, output, addresses, days=90):
    ca_folder, output = Path(ca_folder), Path(output)
    ips = [ipaddress.ip_address(value) for value in addresses]
    if not ips or not 1 <= days <= 365:
        raise ValueError("Explicit server IPs and 1–365 days required")
    if any(ip.is_unspecified or ip.is_multicast for ip in ips):
        raise ValueError("A specific unicast server IP is required")
    if any((output / name).exists() for name in ("server.key", "server.crt")):
        raise ValueError("Use a new output folder for renewal; verify before installing")
    key = serialization.load_pem_private_key((ca_folder / "ca.key").read_bytes(), password=None)
    ca = x509.load_pem_x509_certificate((ca_folder / "ca.crt").read_bytes())
    if key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) != ca.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo):
        raise ValueError("CA certificate and private key do not match")
    now = datetime.now(timezone.utc)
    if not ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca or ca.not_valid_after_utc <= now + timedelta(days=days):
        raise ValueError("CA is invalid or expires before requested server certificate")
    server_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "D.DDECK Server")]))
            .issuer_name(ca.subject).public_key(server_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=days))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip) for ip in ips]), False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)
            .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), True)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), False)
            .sign(key, hashes.SHA256()))
    write_new(output / "server.key", key_bytes(server_key))
    write_new(output / "server.crt", cert.public_bytes(serialization.Encoding.PEM))
    return cert


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["init", "issue"])
    parser.add_argument("--ca-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ip", action="append", default=[])
    parser.add_argument("--days", type=int, default=90)
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == "init":
        cert = create_ca(args.ca_dir)
    else:
        if args.output is None:
            parser.error("--output is required")
        cert = issue(args.ca_dir, args.output, args.ip, args.days)
    print("Certificate SHA256:", cert.fingerprint(hashes.SHA256()).hex())


if __name__ == "__main__":
    main()
