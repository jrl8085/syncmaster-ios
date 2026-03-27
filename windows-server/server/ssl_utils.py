import datetime
import hashlib
import ipaddress
import socket
import ssl
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from .config import CERT_FILE, KEY_FILE


def get_local_ip() -> str:
    """Return the best LAN IP, preferring 192.168.x.x over VPN/VM ranges."""
    candidates: list[str] = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in candidates:
                candidates.append(ip)
    except Exception:
        pass

    # Prefer typical home/office LAN ranges over VPN/VM ranges.
    for prefix in ("192.168.", "172.16.", "172.17.", "172.18.", "172.19.",
                   "172.20.", "172.21.", "172.22.", "172.23.", "172.24.",
                   "172.25.", "172.26.", "172.27.", "172.28.", "172.29.",
                   "172.30.", "172.31."):
        for ip in candidates:
            if ip.startswith(prefix):
                return ip
    for ip in candidates:
        if ip.startswith("10."):
            return ip
    if candidates:
        return candidates[0]

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_all_local_ips() -> list[str]:
    """Return every non-loopback IPv4 address on this machine."""
    ips: list[str] = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                ips.append(ip)
    except Exception:
        pass
    # Always include the routing-based IP as a fallback
    primary = get_local_ip()
    if primary not in ips and not primary.startswith("127."):
        ips.insert(0, primary)
    return ips or [get_local_ip()]


def generate_self_signed_cert(force: bool = False) -> tuple[Path, Path]:
    if not force and CERT_FILE.exists() and KEY_FILE.exists():
        return CERT_FILE, KEY_FILE

    all_ips = get_all_local_ips()
    primary_ip = all_ips[0]
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048, backend=default_backend())

    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "SyncMaster"),
        x509.NameAttribute(NameOID.COMMON_NAME, f"SyncMaster ({primary_ip})"),
    ])

    san_entries = [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
    for ip in all_ips:
        san_entries.append(x509.IPAddress(ipaddress.ip_address(ip)))

    cert = (
        x509.CertificateBuilder()
        .subject_name(subject).issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.utcnow())
        .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=3650))
        .add_extension(x509.SubjectAlternativeName(san_entries), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256(), default_backend())
    )

    KEY_FILE.write_bytes(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()
    ))
    CERT_FILE.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return CERT_FILE, KEY_FILE


def get_cert_fingerprint() -> str:
    if not CERT_FILE.exists():
        return ""
    der = ssl.PEM_cert_to_DER_cert(CERT_FILE.read_text())
    return hashlib.sha256(der).hexdigest()
