"""Tests for server/auth.py — token lifecycle, lockout, idle expiry, rotation."""

from datetime import datetime, timedelta, timezone

import pytest
import yaml

from server.auth import (
    AuthSettings,
    AuthState,
    _parse_issued_at,
    load_auth_settings,
)


def _write(path, auth: dict) -> None:
    path.write_text(yaml.safe_dump({"auth": auth}), encoding="utf-8")


def test_first_run_generates_and_persists_token(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    assert len(settings.token) >= 32
    assert sec.exists()
    again = load_auth_settings(sec)
    assert again.token == settings.token  # stable across restarts


def test_verify_valid_and_invalid(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    assert state.verify(settings.token)
    assert not state.verify("wrong-token")


def test_rate_limit_locks_out(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.max_failed_attempts = 3
    settings.lockout_minutes = 15
    state = AuthState(settings=settings)
    assert not state.verify("bad-1")
    assert not state.verify("bad-2")
    assert not state.verify("bad-3")
    assert state.is_locked()
    # Even the right token is rejected while locked.
    assert not state.verify(settings.token)


def test_lockout_expires(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.max_failed_attempts = 1
    settings.lockout_minutes = 15
    now = [datetime.now(timezone.utc)]
    state = AuthState(settings=settings, now=lambda: now[0])
    assert not state.verify("bad")
    assert state.is_locked()
    now[0] += timedelta(minutes=16)
    assert not state.is_locked()
    assert state.verify(settings.token)


def test_idle_timeout_expires_session(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.idle_timeout_minutes = 60
    now = [datetime.now(timezone.utc)]
    state = AuthState(settings=settings, now=lambda: now[0])
    assert state.verify(settings.token)  # stamps activity
    now[0] += timedelta(minutes=61)
    assert state.is_idle_expired()
    assert not state.verify(settings.token)  # must re-pair


def test_idle_and_absolute_are_distinct_bricks(tmp_path) -> None:
    """Human decision (2): two separate shorter/outer fuses, distinct names.

    idle_timeout (no LAN-surface activity for N minutes) and absolute_max_age
    (hard ceiling from issuance) are different settings, different predicates,
    and different verify_with_code results — a future edit to one rule must
    not silently change the other.
    """
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.idle_timeout_minutes = 60
    settings.token_absolute_max_age_days = 30

    # Idle brick: recent issuance, stale activity.
    now = [datetime.now(timezone.utc)]
    idle = AuthState(settings=settings, now=lambda: now[0])
    assert idle.verify(settings.token)
    now[0] += timedelta(minutes=61)
    ok, code = idle.verify_with_code(settings.token)
    assert not ok and code == "idle_expired"
    assert not idle.is_absolute_expired()  # the OTHER fuse is untouched

    # Absolute brick: fresh activity, ancient issuance.
    old = AuthState(
        settings=settings,
        issued_at=now[0] - timedelta(days=31),
        on_expire=lambda _event, _payload: None,  # keep the notice out of the repo log
    )
    ok, code = old.verify_with_code(settings.token)
    assert not ok and code == "token_expired"
    assert not old.is_idle_expired()  # the OTHER fuse is untouched


def test_rotate_invalidates_old_token(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    old = settings.token
    new = state.rotate(sec)
    assert new != old
    assert not state.verify(old)
    assert state.verify(new)


def test_absolute_ceiling_rejects_despite_continuous_refresh(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.token_absolute_max_age_days = 30
    # Isolate the absolute ceiling from idle expiry (covered separately above).
    settings.idle_timeout_minutes = 60 * 24 * 45
    now = [datetime.now(timezone.utc)]
    events: list = []
    state = AuthState(
        settings=settings,
        issued_at=now[0],
        now=lambda: now[0],
        on_expire=lambda event_type, payload: events.append((event_type, payload)),
    )
    # Daily use slides last_activity forward but must not extend the ceiling.
    for _ in range(29):
        assert state.verify(settings.token)
        now[0] += timedelta(days=1)
    assert state.verify(settings.token)  # T+29d: still under the ceiling
    now[0] += timedelta(days=1, hours=1)  # T+30d+1h: past the ceiling
    assert state.is_absolute_expired()
    assert not state.verify(settings.token)
    assert events and events[-1][0] == "token_expired"
    # Retries after expiry are silent 401s — one log line per token, not N.
    assert not state.verify(settings.token)
    assert len(events) == 1
    assert state.absolute_expired_retries == 1


def test_sliding_refresh_under_ceiling_works(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.token_absolute_max_age_days = 30
    # Isolate sliding refresh from idle expiry (covered separately above).
    settings.idle_timeout_minutes = 60 * 24 * 45
    now = [datetime.now(timezone.utc)]
    events: list = []
    state = AuthState(
        settings=settings,
        issued_at=now[0],
        now=lambda: now[0],
        on_expire=lambda event_type, payload: events.append((event_type, payload)),
    )
    assert state.verify(settings.token)  # T
    now[0] += timedelta(days=10)
    assert state.verify(settings.token)  # T+10d
    now[0] += timedelta(days=10)
    assert state.verify(settings.token)  # T+20d
    now[0] += timedelta(days=9)
    assert state.verify(settings.token)  # T+29d
    assert not state.is_absolute_expired()
    assert events == []  # no forced-expiry notice under the ceiling


def test_token_expired_event_fires_with_stream_shape(tmp_path) -> None:
    import json

    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.token_absolute_max_age_days = 30
    now = [datetime.now(timezone.utc)]
    events: list = []
    state = AuthState(
        settings=settings,
        issued_at=now[0],
        now=lambda: now[0],
        on_expire=lambda event_type, payload: events.append((event_type, payload)),
    )
    now[0] += timedelta(days=31)
    assert not state.verify(settings.token)
    assert len(events) == 1
    event_type, payload = events[0]
    assert event_type == "token_expired"
    assert payload["reason"] == "absolute_max_age"
    assert "expired_at" in payload
    # A wrong token after the ceiling takes the normal failure path: no event.
    assert not state.verify("wrong-token")
    assert len(events) == 1
    # A retry with the expired token is a silent 401: counted, not re-logged.
    assert not state.verify(settings.token)
    assert len(events) == 1
    assert state.absolute_expired_retries == 1
    # Default sink appends the same {"type", "at", **payload} shape the SSE
    # /events endpoint tails (no new logging mechanism).
    log = tmp_path / "events.jsonl"
    file_state = AuthState(
        settings=settings,
        issued_at=state.issued_at,
        now=lambda: now[0],
        event_log=log,
    )
    assert not file_state.verify(settings.token)
    record = json.loads(log.read_text(encoding="utf-8").strip().splitlines()[-1])
    assert record["type"] == "token_expired"
    assert record["reason"] == "absolute_max_age"
    assert "at" in record and "expired_at" in record


def test_absolute_boundary_is_inclusive(tmp_path) -> None:
    """Fail closed: the token is invalid the MOMENT it reaches max age (>=)."""
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    settings.token_absolute_max_age_days = 30
    settings.idle_timeout_minutes = 60 * 24 * 45
    issued = datetime.now(timezone.utc)
    now = [issued]
    state = AuthState(
        settings=settings,
        issued_at=issued,
        now=lambda: now[0],
        on_expire=lambda _event, _payload: None,  # keep the notice out of the repo log
    )
    now[0] = issued + timedelta(days=30) - timedelta(seconds=1)
    assert not state.is_absolute_expired()
    assert state.verify(settings.token)
    now[0] = issued + timedelta(days=30)  # exactly the boundary
    assert state.is_absolute_expired()
    ok, code = state.verify_with_code(settings.token)
    assert not ok and code == "token_expired"


def test_missing_issued_at_is_already_expired(tmp_path) -> None:
    """Legacy file, no recorded issuance: cannot prove any age limit → expired."""
    sec = tmp_path / "security.yaml"
    _write(sec, {"token": "legacy-token", "token_absolute_max_age_days": 30})
    settings = load_auth_settings(sec)
    assert settings.issued_at is None
    events: list = []
    state = AuthState(
        settings=settings,
        now=lambda: datetime.now(timezone.utc),
        on_expire=lambda event_type, payload: events.append((event_type, payload)),
    )
    assert state.is_absolute_expired()
    ok, code = state.verify_with_code("legacy-token")
    assert not ok and code == "token_expired"
    assert [e[0] for e in events] == ["token_expired"]
    # Recovery is the existing pairing flow: rotate() re-pairs with fresh issuance.
    new = state.rotate(sec)
    assert state.verify(new)


def test_naive_issued_at_raises() -> None:
    """Naive datetimes are rejected, never silently assumed UTC."""
    with pytest.raises(ValueError):
        _parse_issued_at("2026-01-01T00:00:00")  # no offset
    with pytest.raises(ValueError):
        _parse_issued_at(datetime(2026, 1, 1, 0, 0, 0))  # naive datetime
    # Aware values still parse.
    assert _parse_issued_at("2026-01-01T00:00:00+00:00") is not None
