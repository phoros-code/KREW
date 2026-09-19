"""Pairing-token auth for the control server (Phase 2).

One-time token generated on first run, bearer-checked on every endpoint
except /health. Rate-limit lockout + idle expiry per config/security.yaml.
See SECURITY.md → Authentication. Anything here needs HUMAN review, not just
tests (CLAUDE.md rule 6).
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

import yaml

from buddy_core.config import CONFIG_DIR

SECURITY_PATH = CONFIG_DIR / "security.yaml"


@dataclass
class AuthSettings:
    token: str = ""
    max_failed_attempts: int = 5
    lockout_minutes: int = 15
    idle_timeout_minutes: int = 60


def load_auth_settings(path: str | Path = SECURITY_PATH) -> AuthSettings:
    """Load settings; generate + persist a token on first run (0600 file mode)."""
    path = Path(path)
    data: dict = {}
    if path.exists():
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    auth = data.get("auth", data)
    settings = AuthSettings(
        token=str(auth.get("token", "") or ""),
        max_failed_attempts=int(auth.get("max_failed_attempts", 5)),
        lockout_minutes=int(auth.get("lockout_minutes", 15)),
        idle_timeout_minutes=int(auth.get("idle_timeout_minutes", 60)),
    )
    if not settings.token:
        settings.token = secrets.token_urlsafe(32)
        data["auth"] = {
            "token": settings.token,
            "token_rotation_days": 30,
            "max_failed_attempts": settings.max_failed_attempts,
            "lockout_minutes": settings.lockout_minutes,
            "idle_timeout_minutes": settings.idle_timeout_minutes,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(data), encoding="utf-8")
        try:
            path.chmod(0o600)
        except OSError:
            pass  # Windows ACLs — file still gitignored; see .gitignore
    return settings


@dataclass
class AuthState:
    """In-memory attempt tracking. One instance per server process."""

    settings: AuthSettings
    failed_attempts: int = 0
    locked_until: datetime | None = None
    last_activity: datetime | None = None
    now: Callable[[], datetime] = field(
        default_factory=lambda: (lambda: datetime.now(timezone.utc))
    )

    def is_locked(self) -> bool:
        return self.locked_until is not None and self.now() < self.locked_until

    def is_idle_expired(self) -> bool:
        if self.last_activity is None:
            return False
        return self.now() - self.last_activity > timedelta(minutes=self.settings.idle_timeout_minutes)

    def verify(self, token: str) -> bool:
        """Check a bearer token. True on success (resets failures, stamps activity)."""
        if self.is_locked() or self.is_idle_expired():
            return False
        if token and secrets.compare_digest(token, self.settings.token):
            self.failed_attempts = 0
            self.locked_until = None
            self.last_activity = self.now()
            return True
        self.failed_attempts += 1
        if self.failed_attempts >= self.settings.max_failed_attempts:
            self.locked_until = self.now() + timedelta(minutes=self.settings.lockout_minutes)
        return False

    def rotate(self, path: str | Path = SECURITY_PATH) -> str:
        """Invalidate the current token immediately (lost-phone procedure)."""
        new_token = secrets.token_urlsafe(32)
        self.settings.token = new_token
        self.failed_attempts = 0
        self.locked_until = None
        self.last_activity = None
        path = Path(path)
        data: dict = {}
        if path.exists():
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        data.setdefault("auth", {})["token"] = new_token
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(data), encoding="utf-8")
        return new_token
