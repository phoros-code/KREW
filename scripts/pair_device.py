"""Print pairing info for the phone app: LAN IP(s), port, token, cert fingerprint.

Usage: python scripts/pair_device.py
The token is shown ONCE on this laptop screen and typed/scanned into the phone,
which stores it in secure storage (Keystore/Keychain). See SECURITY.md.
"""

from __future__ import annotations

import hashlib
import socket
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from server.auth import load_auth_settings


def lan_ips() -> list[str]:
    ips: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                ips.add(ip)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            ips.add(s.getsockname()[0])
    except OSError:
        pass
    return sorted(ips)


def cert_fingerprint() -> str:
    pem = Path("certs/dev-cert.pem")
    if not pem.exists():
        return "(no cert yet — run scripts/gen_cert.ps1)"
    body = "".join(
        line.strip() for line in pem.read_text().splitlines() if "BEGIN" not in line and "END" not in line
    )
    import base64

    return hashlib.sha256(base64.b64decode(body)).hexdigest()


def main() -> int:
    settings = load_auth_settings()
    print("=== Everyday Buddy pairing ===")
    print(f"LAN IP(s) : {', '.join(lan_ips()) or '(unknown)'}")
    print("Port      : 8443 (https)")
    print(f"Token     : {settings.token}")
    print(f"Cert SHA256: {cert_fingerprint()}")
    print("Enter the IP + token in the phone app, verify the fingerprint matches.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
