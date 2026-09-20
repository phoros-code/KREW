"""Phase 4 hardening regression tests (security review).

Covers the small fixes from the security review — each test pins a
fail-closed behaviour so it can't silently regress:
- shell.py: lone-& chaining + NUL bytes blocked (SECURITY.md Tool sandboxing)
- files.py: UNC / drive-letter / ADS / NUL paths rejected (Tool sandboxing)
- auth.py: rotate() clears lockout+idle and keeps file mode tight (Auth)
- streams.py: consent store is count-bounded (Consent / DoS)
- main.py: no unauthenticated docs/openapi surface; error bodies leak nothing
"""

import sys
from datetime import datetime, timezone

import pytest
import yaml
from fastapi.testclient import TestClient

from buddy_core.config import FilesConfig, ShellConfig
from buddy_core.tools import files, shell
from buddy_core.tools.files import FileAccessDenied
from buddy_core.tools.shell import ShellDenied
from server import streams
from server.auth import AuthState, load_auth_settings
from server.main import RateLimiter, create_app, load_network_config

PY = sys.executable
TOKEN = "test-token-123"


# --- shell.py: metachar coverage ---


@pytest.fixture()
def shell_cfg() -> ShellConfig:
    return ShellConfig(
        allowlist=[f"{PY} *", "echo *", "git *"],
        denylist=["rm -rf*", "*format*", "*evil*"],
    )


def test_lone_ampersand_blocked(shell_cfg: ShellConfig) -> None:
    """cmd.exe chains on a single `&` — `&&` coverage alone is not enough."""
    assert not shell.is_allowed("echo hi & dir", shell_cfg)
    with pytest.raises(ShellDenied):
        shell.check_allowed("echo hi & dir", shell_cfg)


def test_nul_byte_blocked(shell_cfg: ShellConfig) -> None:
    with pytest.raises(ShellDenied):
        shell.check_allowed("echo hi\x00", shell_cfg)


def test_legit_commands_still_allowed(shell_cfg: ShellConfig) -> None:
    assert shell.is_allowed("echo hello", shell_cfg)
    res = shell.run(f"{PY} -c \"print('hi-buddy')\"", shell_cfg, timeout_seconds=30)
    assert res.ok and "hi-buddy" in res.stdout


# --- files.py: path-resolution edge cases ---


@pytest.fixture()
def files_cfg(tmp_path) -> FilesConfig:
    return FilesConfig(workspace_root=str(tmp_path / "ws"), allow_outside_workspace=False)


def test_unc_paths_rejected(files_cfg: FilesConfig) -> None:
    for evil in (r"\\server\share\evil.txt", "//server/share/evil.txt"):
        with pytest.raises(FileAccessDenied):
            files.read_text(evil, files_cfg)
        with pytest.raises(FileAccessDenied):
            files.write_text(evil, "x", files_cfg)


def test_drive_letter_paths_rejected(files_cfg: FilesConfig) -> None:
    """Denied on ANY host OS — on POSIX these would parse as relative names."""
    for evil in ("C:/Windows/win.ini", "C:\\Windows\\win.ini", "D:foo", "C:"):
        with pytest.raises(FileAccessDenied):
            files.read_text(evil, files_cfg)


def test_ads_stream_rejected(files_cfg: FilesConfig) -> None:
    """file.txt:hidden is invisible to list_dir — a stealth channel. Denied."""
    with pytest.raises(FileAccessDenied):
        files.write_text("notes/file.txt:hidden", "stealth", files_cfg)


def test_nul_in_path_rejected(files_cfg: FilesConfig) -> None:
    with pytest.raises(FileAccessDenied):
        files.read_text("a\x00b.txt", files_cfg)


def test_legit_workspace_use_unaffected(files_cfg: FilesConfig) -> None:
    files.write_text("notes/hello.txt", "hi buddy", files_cfg)
    assert files.read_text("notes/hello.txt", files_cfg) == "hi buddy"


# --- auth.py: rotation recovers lockout + idle ---


def _write_auth(path, **overrides) -> None:
    auth = {
        "token": "old-token",
        "max_failed_attempts": 2,
        "lockout_minutes": 15,
        "idle_timeout_minutes": 60,
        "token_absolute_max_age_days": 30,
        "issued_at": datetime.now(timezone.utc).isoformat(),
    }
    auth.update(overrides)
    path.write_text(yaml.safe_dump({"auth": auth}), encoding="utf-8")


def test_rotate_clears_lockout(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _write_auth(sec)
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    assert not state.verify("bad-1")
    assert not state.verify("bad-2")
    assert state.is_locked()
    new = state.rotate(sec)
    assert not state.is_locked()
    assert state.verify(new)
    assert not state.verify("old-token")


def test_rotate_recovers_idle_expiry(tmp_path) -> None:
    """Idle expiry bricks the old token (fail closed); rotation re-pairs."""
    from datetime import datetime, timedelta, timezone

    sec = tmp_path / "security.yaml"
    _write_auth(sec)
    settings = load_auth_settings(sec)
    now = [datetime.now(timezone.utc)]
    state = AuthState(settings=settings, now=lambda: now[0])
    assert state.verify("old-token")
    now[0] += timedelta(minutes=61)
    assert not state.verify("old-token")  # idle-expired: even valid token fails
    new = state.rotate(sec)
    assert state.verify(new)


def test_rotate_preserves_other_auth_keys(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _write_auth(sec)
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    state.rotate(sec)
    data = yaml.safe_load(sec.read_text(encoding="utf-8"))
    assert data["auth"]["max_failed_attempts"] == 2
    assert data["auth"]["lockout_minutes"] == 15


# --- streams.py: bounded consent store ---


def test_consent_store_evicts_oldest_pending_first() -> None:
    now = [1000.0]
    ids = iter([f"id-{n}" for n in range(10)])
    mgr = streams.ConsentManager(now=lambda: now[0], new_id=lambda: next(ids), max_records=3)
    a = mgr.start_consent_request()  # id-0
    b = mgr.start_consent_request()  # id-1
    live = mgr.start_consent_request()  # id-2
    assert mgr.approve(live) is True  # live grant must survive eviction
    now[0] += 1
    d = mgr.start_consent_request()  # id-3 -> over cap, evicts id-0
    assert mgr.status_of(a) is None
    assert mgr.status_of(b) is streams.ConsentStatus.PENDING
    assert mgr.is_approved(live) is True
    assert mgr.status_of(d) is streams.ConsentStatus.PENDING


def test_consent_store_stays_bounded_under_spam() -> None:
    mgr = streams.ConsentManager(max_records=8)
    for _ in range(50):
        mgr.start_consent_request()
    assert len(mgr._records) <= 8


# --- main.py: unauthenticated surface + error-shape leakage ---


def _security(path, mode="lan_only", rate: int | None = None) -> None:
    doc = {
        "auth": {
            "token": TOKEN,
            "max_failed_attempts": 5,
            "lockout_minutes": 15,
            "idle_timeout_minutes": 60,
            "token_absolute_max_age_days": 30,
            "issued_at": datetime.now(timezone.utc).isoformat(),
        },
        "proximity": {"mode": mode, "rssi_near_threshold": -60, "fail_mode": "far"},
    }
    if rate is not None:
        doc["network"] = {"rate_limit_per_minute": rate}
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


@pytest.fixture()
def app_lan(tmp_path):
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


def test_no_unauthenticated_docs_or_openapi(app_lan) -> None:
    """SECURITY.md: only /health is unauthenticated — docs must not exist."""
    assert app_lan.docs_url is None
    assert app_lan.redoc_url is None
    assert app_lan.openapi_url is None
    client = TestClient(app_lan)
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404
    assert client.get("/redoc").status_code == 404


def test_error_bodies_do_not_echo_credentials(app_lan) -> None:
    client = TestClient(app_lan)
    probe = "attacker-probe-token-xyz"
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer {probe}"})
    assert resp.status_code == 401
    assert probe not in resp.text
    assert resp.json()["error"]["code"] == "unauthorized"


def test_lockout_shape_is_generic(app_lan) -> None:
    """429 reveals only that the gate is shut — no token/state detail."""
    client = TestClient(app_lan)
    for n in range(6):
        client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer bad-{n}"})
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": "Bearer bad-final"})
    assert resp.status_code == 429
    assert "bad-final" not in resp.text
    assert resp.json()["error"]["code"] == "locked_out"


# --- main.py: per-IP request throttle (Phase 4, review item 3) ---


def test_rate_limiter_unit_window_and_reset() -> None:
    now = [1000.0]
    lim = RateLimiter(per_minute=2, now=lambda: now[0])
    assert lim.allow("1.2.3.4") == (True, 0.0)
    assert lim.allow("1.2.3.4")[0] is True
    ok, retry_after = lim.allow("1.2.3.4")
    assert ok is False
    assert retry_after > 0
    now[0] += 61.0  # next window — no sleeping in tests
    assert lim.allow("1.2.3.4")[0] is True


def test_rate_limiter_unit_per_key_isolation() -> None:
    lim = RateLimiter(per_minute=1)
    assert lim.allow("a")[0] is True
    assert lim.allow("a")[0] is False
    assert lim.allow("b")[0] is True  # one noisy IP must not starve the rest


def test_rate_limit_config_defaults_fail_safe(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    sec.write_text(yaml.safe_dump({"auth": {"token": "x"}}), encoding="utf-8")
    assert load_network_config(sec)["rate_limit_per_minute"] == 60
    for bad in ("garbage", 0, -5, None):
        sec.write_text(
            yaml.safe_dump({"auth": {"token": "x"}, "network": {"rate_limit_per_minute": bad}}),
            encoding="utf-8",
        )
        assert load_network_config(sec)["rate_limit_per_minute"] == 60


def test_rate_limit_429_integration(tmp_path) -> None:
    """The declared cap is actually enforced — 4th request in a 3/min window."""
    sec = tmp_path / "security.yaml"
    _security(sec, rate=3)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    for _ in range(3):
        assert client.get("/health").status_code == 200
    resp = client.get("/health")
    assert resp.status_code == 429
    assert resp.json()["error"]["code"] == "rate_limited"
    assert "Retry-After" in resp.headers
    assert TOKEN not in resp.text


def test_rate_limit_leaves_normal_use_alone(app_lan) -> None:
    """Default 60/min cap must not trip on ordinary request bursts."""
    client = TestClient(app_lan)
    for _ in range(10):
        assert client.get("/health").status_code == 200
