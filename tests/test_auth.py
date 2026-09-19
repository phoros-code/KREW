"""Tests for server/auth.py — token lifecycle, lockout, idle expiry, rotation."""

from datetime import datetime, timedelta, timezone

import yaml

from server.auth import AuthSettings, AuthState, load_auth_settings


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


def test_rotate_invalidates_old_token(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    old = settings.token
    new = state.rotate(sec)
    assert new != old
    assert not state.verify(old)
    assert state.verify(new)
