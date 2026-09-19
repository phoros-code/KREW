"""Generate a local dev TLS certificate (zero-dependency fallback to mkcert).

Prefer mkcert per SECURITY.md; this script needs only the `cryptography`
package and writes certs/dev-cert.pem + certs/dev-key.pem (both gitignored).

Usage: python scripts/gen_cert.py
"""

from __future__ import annotations

import socket
from datetime import datetime, timedelta, timezone
from pathlib import Path

CERT_PATH = Path("certs/dev-cert.pem")
KEY_PATH = Path("certs/dev-key.pem")


def main() -> int:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    names = [x509.DNSName("buddy.local"), x509.DNSName(socket.gethostname())]
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "buddy.local")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + timedelta(days=730))
        .add_extension(x509.SubjectAlternativeName(names), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    CERT_PATH.parent.mkdir(parents=True, exist_ok=True)
    CERT_PATH.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    KEY_PATH.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    print(f"wrote {CERT_PATH} + {KEY_PATH}")
    print("SHA256 fingerprint:", cert.fingerprint(hashes.SHA256()).hex())
    print("Pin this fingerprint in the phone app on first pairing (SECURITY.md).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
