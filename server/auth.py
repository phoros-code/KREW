"""Pairing-token auth for the control server (Phase 2).

One-time token generated on first run, bearer-checked on every endpoint
except /health. Rate-limit lockout + idle expiry per config/security.yaml.
See SECURITY.md → Authentication. Anything here needs HUMAN review, not just
tests (CLAUDE.md rule 6).
"""

from __future__ import annotations

import json
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

import yaml

from buddy_core.config import CONFIG_DIR

SECURITY_PATH = CONFIG_DIR / "security.yaml"

# Default hard ceiling for a pairing token, in days. Overridden by
# config/security.yaml → auth.token_absolute_max_age_days (never hardcoded
# at the call site). Sliding idle refresh (last_activity) never extends this.
DEFAULT_ABSOLUTE_MAX_AGE_DAYS = 30

# Same file the SSE /events endpoint tails (server/main.py default and
# buddy_core/orchestrator.py EVENT_LOG). Reuses that stream — no new
# notification path. Overridable per AuthState for tests.
DEFAULT_EVENT_LOG = CONFIG_DIR.parent / "logs" / "events.jsonl"

TOKEN_EXPIRED_EVENT = "token_expired"


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _parse_issued_at(value: object) -> datetime | None:
    """Parse a persisted issued_at (ISO string or yaml-parsed datetime).

    Returns None only when the key is absent (legacy file → caller treats a
    missing issuance as already-expired, fail closed). Naive datetimes are
    REJECTED with ValueError, never silently assumed to be UTC — a silent
    assumption shifts the ceiling by the local offset unnoticed.
    """
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            raise ValueError("issued_at must be timezone-aware (UTC ISO-8601), got naive datetime")
        return value
    if isinstance(value, str):
        parsed = datetime.fromisoformat(value)  # garbage propagates as ValueError (loud)
        if parsed.tzinfo is None:
            raise ValueError("issued_at must carry a UTC offset, got naive string")
        return parsed
    raise ValueError(f"issued_at has unsupported type: {type(value).__name__}")


def _parse_absolute_max_age_days(value: object) -> int:
    try:
        days = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_ABSOLUTE_MAX_AGE_DAYS
    return days if days >= 1 else DEFAULT_ABSOLUTE_MAX_AGE_DAYS


@dataclass
class AuthSettings:
    token: str = ""
    max_failed_attempts: int = 5
    lockout_minutes: int = 15
    idle_timeout_minutes: int = 60
    # Hard ceiling (days) from issuance — sliding activity never extends it.
    token_absolute_max_age_days: int = DEFAULT_ABSOLUTE_MAX_AGE_DAYS
    # When the current token was issued (persisted in security.yaml).
    issued_at: datetime | None = None


def _persist_auth_file(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data), encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass  # Windows ACLs — file still gitignored; see .gitignore


def load_auth_settings(path: str | Path = SECURITY_PATH) -> AuthSettings:
    """Load settings; generate + persist a token on first run (0600 file mode)."""
    path = Path(path)
    data: dict = {}
    if path.exists():
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    auth = data.get("auth", data)
    issued_at = _parse_issued_at(auth.get("issued_at"))
    settings = AuthSettings(
        token=str(auth.get("token", "") or ""),
        max_failed_attempts=int(auth.get("max_failed_attempts", 5)),
        lockout_minutes=int(auth.get("lockout_minutes", 15)),
        idle_timeout_minutes=int(auth.get("idle_timeout_minutes", 60)),
        token_absolute_max_age_days=_parse_absolute_max_age_days(
            auth.get("token_absolute_max_age_days", DEFAULT_ABSOLUTE_MAX_AGE_DAYS)
        ),
        issued_at=issued_at,
    )
    if not settings.token:
        settings.token = secrets.token_urlsafe(32)
        settings.issued_at = _utcnow()
        data["auth"] = {
            "token": settings.token,
            "token_rotation_days": auth.get("token_rotation_days", 30),
            "token_absolute_max_age_days": settings.token_absolute_max_age_days,
            "max_failed_attempts": settings.max_failed_attempts,
            "lockout_minutes": settings.lockout_minutes,
            "idle_timeout_minutes": settings.idle_timeout_minutes,
            "issued_at": settings.issued_at.isoformat(),
        }
        _persist_auth_file(path, data)
        return settings
    # No backfill of issued_at here: a token with no recorded issuance is one
    # we cannot prove is within any age limit, so it stays None and verifies
    # as already-expired (fail closed — forces re-pair via rotate()).
    return settings


@dataclass
class AuthState:
    """In-memory attempt tracking. One instance per server process."""

    settings: AuthSettings
    failed_attempts: int = 0
    locked_until: datetime | None = None
    last_activity: datetime | None = None
    # Test override for issuance time; falls back to settings.issued_at.
    issued_at: datetime | None = None
    now: Callable[[], datetime] = field(
        default_factory=lambda: (lambda: datetime.now(timezone.utc))
    )
    # Sink for the forced-expiry notice. Defaults to appending
    # {"type": "token_expired", ...} to the SSE-tailed events.jsonl (same
    # shape as orchestrator._log_event records — no new logging mechanism).
    # Tests inject a list-append callable instead of touching disk.
    on_expire: Callable[[str, dict], None] | None = None
    event_log: str | Path | None = None
    # Dedup: the expiry notice fires ONCE per token. Post-expiry retries get
    # a silent 401 (no new log line — disk-fill vector otherwise). Retries
    # are counted in-memory for debugging, never logged per attempt.
    _emitted_for_token: str | None = None
    absolute_expired_retries: int = 0

    def effective_issued_at(self) -> datetime | None:
        if self.issued_at is not None:
            return self.issued_at
        return self.settings.issued_at

    def is_locked(self) -> bool:
        return self.locked_until is not None and self.now() < self.locked_until

    def is_idle_expired(self) -> bool:
        if self.last_activity is None:
            return False
        return self.now() - self.last_activity > timedelta(minutes=self.settings.idle_timeout_minutes)

    def is_absolute_expired(self) -> bool:
        """Hard ceiling from issuance — True even with recent activity.

        Fail-closed on both axes: the boundary is INCLUSIVE (>= — the token
        is no longer valid the moment it reaches max age, not one tick past),
        and an unknown issuance (None) counts as expired, never as valid.
        """
        effective = self.effective_issued_at()
        if effective is None:
            return True
        return self.now() - effective >= timedelta(days=self.settings.token_absolute_max_age_days)

    def _emit_token_expired(self) -> None:
        """Notify via the existing SSE stream file. Never raises (must not block the 401)."""
        payload = {"reason": "absolute_max_age", "expired_at": self.now().isoformat()}
        if self.on_expire is not None:
            try:
                self.on_expire(TOKEN_EXPIRED_EVENT, payload)
            except Exception:
                pass
            return
        try:
            log_path = Path(self.event_log) if self.event_log else DEFAULT_EVENT_LOG
            log_path.parent.mkdir(parents=True, exist_ok=True)
            record = {"type": TOKEN_EXPIRED_EVENT, "at": self.now().isoformat(), **payload}
            with log_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(record) + "\n")
        except Exception:
            pass

    def verify_with_code(self, token: str) -> tuple[bool, str]:
        """Check a bearer token, labelling WHY it failed.

        Codes: "ok" | "locked_out" | "token_expired" | "idle_expired" |
        "unauthorized". Lets the caller return a per-connection 401 code for
        the ceiling (scoped signal) instead of overloading the broadcast log.
        """
        if self.is_locked():
            return False, "locked_out"
        # Absolute ceiling only applies to the real token — a wrong token takes
        # the normal failure path with no event (avoids leaking expiry + log flood).
        if token and secrets.compare_digest(token, self.settings.token):
            if self.is_absolute_expired():
                if self._emitted_for_token != self.settings.token:
                    self._emitted_for_token = self.settings.token
                    self._emit_token_expired()
                else:
                    self.absolute_expired_retries += 1
                return False, "token_expired"
            if self.is_idle_expired():
                return False, "idle_expired"
            self.failed_attempts = 0
            self.locked_until = None
            self.last_activity = self.now()
            return True, "ok"
        if self.is_idle_expired():
            return False, "idle_expired"
        self.failed_attempts += 1
        if self.failed_attempts >= self.settings.max_failed_attempts:
            self.locked_until = self.now() + timedelta(minutes=self.settings.lockout_minutes)
        return False, "unauthorized"

    def verify(self, token: str) -> bool:
        """Check a bearer token. True on success (resets failures, stamps activity)."""
        ok, _ = self.verify_with_code(token)
        return ok

    def rotate(self, path: str | Path = SECURITY_PATH) -> str:
        """Invalidate the current token immediately (lost-phone procedure)."""
        new_token = secrets.token_urlsafe(32)
        self.settings.token = new_token
        self.settings.issued_at = self.now()
        self.issued_at = None  # fall back to settings.issued_at from here on
        self.failed_attempts = 0
        self.locked_until = None
        self.last_activity = None
        self._emitted_for_token = None  # new token gets its own one-time notice
        self.absolute_expired_retries = 0
        path = Path(path)
        data: dict = {}
        if path.exists():
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        data.setdefault("auth", {})["token"] = new_token
        data["auth"]["issued_at"] = self.settings.issued_at.isoformat()
        _persist_auth_file(path, data)
        return new_token
