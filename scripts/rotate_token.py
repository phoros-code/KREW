"""Regenerate the pairing token (lost-phone / leak procedure). Laptop-only.

Usage:
    python scripts/rotate_token.py [--security-path PATH]

Generates a fresh token, persists it via server.auth helpers (atomic write,
0600, shared write lock), and prints it ONCE — the operator types/scans it
into the phone, which stores it in secure storage. The old token stops
working immediately. See SECURITY.md → Incident response.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from server.auth import SECURITY_PATH, AuthState, load_auth_settings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Regenerate the Everyday Buddy pairing token.")
    parser.add_argument(
        "--security-path",
        default=str(SECURITY_PATH),
        help="Path to security.yaml (default: config/security.yaml)",
    )
    args = parser.parse_args(argv)
    sec_path = Path(args.security_path)
    settings = load_auth_settings(sec_path)
    state = AuthState(settings=settings)
    new_token = state.rotate(sec_path)
    # Printed exactly once — no logging, no duplicate copies.
    print(new_token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
