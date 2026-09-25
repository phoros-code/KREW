"""Pairing-token auth for the control server (Phase 2).

One-time token generated on first run, bearer-checked on every endpoint
except /health. Rate-limit lockout + idle expiry per config/security.yaml.
See SECURITY.md → Authentication. Anything here needs HUMAN review, not just
tests (CLAUDE.md rule 6).
"""

from __future__ import annotations

import json
import os
import secrets
import tempfile
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

import yaml

from buddy_core.config import CONFIG_DIR

# Single module-level lock shared by ALL security.yaml writers: threshold
# write (server/main.py), _persist_auth_file, and the rotate() path.
# Guarantees concurrent threshold+persist/rotate never interleave a
# read-modify-write into a corrupt or half-merged file. threading.Lock
# (not RLock): callers must not nest — _atomic_write_yaml assumes the lock
# is already held; _persist_auth_file acquires it once.
_SECURITY_WRITE_LOCK = threading.Lock()

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


def generate_approval_secret() -> str:
    """Generate a 64-hex laptop-only consent approval secret.

    Same pattern as the pairing-token generation below (secrets module,
    persisted to security.yaml on first run). The phone never sees this
    value — approval requires loopback origin OR the X-Buddy-Approval
    header matching it (see server/main.py require_approval).
    """
    return secrets.token_hex(32)


def is_valid_approval_secret(value: object) -> bool:
    """True only for a 64-char hex string (case-insensitive)."""
    if not isinstance(value, str):
        return False
    text = value.strip()
    if len(text) != 64:
        return False
    try:
        int(text, 16)
    except ValueError:
        return False
    return True


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
    # Laptop-only consent approval secret (64-hex). Empty means "not
    # configured" — legacy/test files without it keep the pre-A3
    # phone-token approval path so existing tests stay green; fresh
    # installs generate + persist one (see load_auth_settings).
    consent_approval_secret: str = ""


def _atomic_write_yaml(path: Path, data: dict) -> None:
    """Atomically replace `path` with `data` (YAML). Caller holds _SECURITY_WRITE_LOCK.

    Unique tmp name via tempfile.mkstemp (no fixed ".tmp" collision), fsync
    before rename so a crash can't leave a truncated file, chmod 0600,
    then atomic os.replace. Cleans up the tmp file on failure.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=str(path.parent), prefix=path.name + ".", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(yaml.safe_dump(data))
            fh.flush()
            try:
                os.fsync(fh.fileno())
            except OSError:
                pass  # e.g. in-memory filesystems in tests
        try:
            os.chmod(tmp_name, 0o600)
        except OSError:
            pass  # Windows ACLs — file still gitignored; see .gitignore
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def _persist_auth_file(path: Path, data: dict) -> None:
    path = Path(path)
    with _SECURITY_WRITE_LOCK:
        _atomic_write_yaml(path, data)


def load_auth_settings(path: str | Path = SECURITY_PATH) -> AuthSettings:
    """Load settings; generate + persist a token on first run (0600 file mode)."""
    path = Path(path)
    data: dict = {}
    if path.exists():
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            raise RuntimeError(f"corrupt security config: {path}: {exc}") from exc
    auth = data.get("auth", data)
    issued_at = _parse_issued_at(auth.get("issued_at"))
    raw_secret = auth.get("consent_approval_secret", "")
    approval_secret = str(raw_secret or "").strip()
    settings = AuthSettings(
        token=str(auth.get("token", "") or ""),
        max_failed_attempts=int(auth.get("max_failed_attempts", 5)),
        lockout_minutes=int(auth.get("lockout_minutes", 15)),
        idle_timeout_minutes=int(auth.get("idle_timeout_minutes", 60)),
        token_absolute_max_age_days=_parse_absolute_max_age_days(
            auth.get("token_absolute_max_age_days", DEFAULT_ABSOLUTE_MAX_AGE_DAYS)
        ),
        issued_at=issued_at,
        consent_approval_secret=approval_secret,
    )
    if not settings.token:
        settings.token = secrets.token_urlsafe(32)
        settings.issued_at = _utcnow()
        if not settings.consent_approval_secret:
            settings.consent_approval_secret = generate_approval_secret()
        data["auth"] = {
            "token": settings.token,
            "consent_approval_secret": settings.consent_approval_secret,
            "token_rotation_days": auth.get("token_rotation_days", 30),
            "token_absolute_max_age_days": settings.token_absolute_max_age_days,
            "max_failed_attempts": settings.max_failed_attempts,
            "lockout_minutes": settings.lockout_minutes,
            "idle_timeout_minutes": settings.idle_timeout_minutes,
            "issued_at": settings.issued_at.isoformat(),
        }
        _persist_auth_file(path, data)
        return settings
    if not settings.consent_approval_secret:
        # Fail closed: legacy files that predate the approval secret get one
        # generated and persisted on load, so the laptop-only approval gate
        # is always armed — an existing install never silently keeps the
        # pre-A3 phone-can-approve behavior.
        settings.consent_approval_secret = generate_approval_secret()
        if "auth" in data and isinstance(data["auth"], dict):
            data["auth"]["consent_approval_secret"] = settings.consent_approval_secret
        else:
            data["consent_approval_secret"] = settings.consent_approval_secret
        _persist_auth_file(path, data)
    # No backfill of issued_at here: a token with no recorded issuance is one
    # we cannot prove is within any age limit, so it stays None and verifies
    # as already-expired (fail closed — forces re-pair via rotate()).
    return settings


@dataclass
class AuthState:
    """In-memory attempt tracking. One instance per server process."""

    settings: AuthSettings
    # Per-client-IP lockout state (Track A1). Keys are client IPs
    # ("unknown" when the transport supplies none). A noisy or hostile IP
    # can lock ITSELF out after max_failed_attempts, but never another IP.
    # Backwards compat: verify()/is_locked() default to the "unknown" key,
    # so existing single-IP call sites keep working unchanged.
    failed_attempts: dict[str, int] = field(default_factory=dict)
    locked_until: dict[str, datetime | None] = field(default_factory=dict)
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

    @staticmethod
    def _ip_key(client_ip: str | None) -> str:
        return client_ip if client_ip else "unknown"

    def is_locked(self, client_ip: str | None = None) -> bool:
        """Per-IP lockout check. None (legacy call) = ANY IP locked."""
        if client_ip is None:
            now = self.now()
            return any(
                until is not None and now < until for until in self.locked_until.values()
            )
        key = self._ip_key(client_ip)
        until = self.locked_until.get(key)
        return until is not None and self.now() < until

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

    def verify_with_code(self, token: str, client_ip: str | None = None) -> tuple[bool, str]:
        """Check a bearer token, labelling WHY it failed.

        Codes: "ok" | "locked_out" | "token_expired" | "idle_expired" |
        "unauthorized". Lets the caller return a per-connection 401 code for
        the ceiling (scoped signal) instead of overloading the broadcast log.

        Lockout is per client IP: `client_ip` selects the failure bucket
        (None/"" → "unknown"). Success clears ONLY that IP's bucket; a wrong
        token increments ONLY that IP's counter.
        """
        key = self._ip_key(client_ip)
        if self.is_locked(key):
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
            self.failed_attempts.pop(key, None)
            self.locked_until.pop(key, None)
            self.last_activity = self.now()
            return True, "ok"
        if self.is_idle_expired():
            return False, "idle_expired"
        count = self.failed_attempts.get(key, 0) + 1
        self.failed_attempts[key] = count
        if count >= self.settings.max_failed_attempts:
            self.locked_until[key] = self.now() + timedelta(minutes=self.settings.lockout_minutes)
        return False, "unauthorized"

    def verify(self, token: str, client_ip: str | None = None) -> bool:
        """Check a bearer token. True on success (resets failures, stamps activity)."""
        ok, _ = self.verify_with_code(token, client_ip)
        return ok

    def rotate(self, path: str | Path = SECURITY_PATH) -> str:
        """Invalidate the current token immediately (lost-phone procedure)."""
        new_token = secrets.token_urlsafe(32)
        self.settings.token = new_token
        self.settings.issued_at = self.now()
        self.issued_at = None  # fall back to settings.issued_at from here on
        if isinstance(self.failed_attempts, dict):
            self.failed_attempts.clear()
        else:  # pragma: no cover — legacy int shape, never written now
            self.failed_attempts = {}  # type: ignore[assignment]
        if isinstance(self.locked_until, dict):
            self.locked_until.clear()
        else:  # pragma: no cover — legacy shape
            self.locked_until = {}  # type: ignore[assignment]
        self.last_activity = None
        self._emitted_for_token = None  # new token gets its own one-time notice
        self.absolute_expired_retries = 0
        path = Path(path)
        # Hold the shared write lock across read-modify-write so a
        # concurrent threshold write can't interleave into a torn file.
        # _atomic_write_yaml assumes the lock is held (no nested acquire).
        with _SECURITY_WRITE_LOCK:
            data: dict = {}
            if path.exists():
                try:
                    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
                except yaml.YAMLError:
                    data = {}
                if not isinstance(data, dict):
                    data = {}
            data.setdefault("auth", {})["token"] = new_token
            data["auth"]["issued_at"] = self.settings.issued_at.isoformat()
            _atomic_write_yaml(path, data)
        return new_token
