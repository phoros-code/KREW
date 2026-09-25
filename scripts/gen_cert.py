"""Generate a local dev TLS certificate (zero-dependency fallback to mkcert).

Prefer mkcert per SECURITY.md; this script needs only the `cryptography`
package and writes <out-dir>/dev-cert.pem + <out-dir>/dev-key.pem (both
gitignored).

Usage: python scripts/gen_cert.py [--out-dir certs]
"""

from __future__ import annotations

import argparse
import socket
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_OUT_DIR = Path("certs")
CERT_NAME = "dev-cert.pem"
KEY_NAME = "dev-key.pem"

# Default output paths (kept for backwards compat — main() derives these
# from --out-dir, which defaults here).
CERT_PATH = DEFAULT_OUT_DIR / CERT_NAME
KEY_PATH = DEFAULT_OUT_DIR / KEY_NAME


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a local dev TLS certificate.")
    parser.add_argument(
        "--out-dir",
        default=str(DEFAULT_OUT_DIR),
        help="Directory for dev-cert.pem + dev-key.pem (default: certs).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    args = parse_args(argv)
    out_dir = Path(args.out_dir)
    cert_path = out_dir / CERT_NAME
    key_path = out_dir / KEY_NAME

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
    cert_path.parent.mkdir(parents=True, exist_ok=True)
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    print(f"wrote {cert_path} + {key_path}")
    print("SHA256 fingerprint:", cert.fingerprint(hashes.SHA256()).hex())
    print("Pin this fingerprint in the phone app on first pairing (SECURITY.md).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
