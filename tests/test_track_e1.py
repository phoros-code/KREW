"""Track E1 (security-review BLOCKER + SHOULDs + NOTEs) tests."""

from __future__ import annotations

import json
import socket as std_socket
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest
import yaml
from fastapi.testclient import TestClient
from starlette.exceptions import HTTPException as StarletteHTTPException

import buddy_core.orchestrator as orch
from buddy_core.tools import web_search
from server.auth import AuthState, load_auth_settings
from server.main import create_app

TOKEN = "test-token-123"
SECRET = "b2" * 32

_PUBLIC = [(std_socket.AF_INET, std_socket.SOCK_STREAM, 6, "", ("93.184.216.34", 0))]
_PRIVATE = [(std_socket.AF_INET, std_socket.SOCK_STREAM, 6, "", ("10.1.2.3", 0))]


def _security(path: Path, mode: str = "lan_only") -> None:
    doc = {
        "auth": {
            "token": TOKEN,
            "consent_approval_secret": SECRET,
            "max_failed_attempts": 5,
            "lockout_minutes": 15,
            "idle_timeout_minutes": 60,
            "token_absolute_max_age_days": 30,
            "issued_at": datetime.now(timezone.utc).isoformat(),
        },
        "proximity": {"mode": mode, "rssi_near_threshold": -60, "fail_mode": "far"},
    }
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


def _auth(token: str = TOKEN, extra: dict | None = None) -> dict:
    h = {"Authorization": f"Bearer {token}"}
    if extra:
        h.update(extra)
    return h


# --- 1. BLOCKER-01 live rotation on the RUNNING app ---


def test_live_rotation_running_app_rejects_old(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    assert client.get("/proximity", headers=_auth()).status_code == 200
    # CLI-equivalent: separate load + rotate + persist, like scripts/rotate_token.py.
    settings2 = load_auth_settings(sec)
    state2 = AuthState(settings=settings2)
    new_token = state2.rotate(sec)
    assert new_token != TOKEN
    # RUNNING app, no rebuild: old 401, new 200 within one request each.
    assert client.get("/proximity", headers=_auth(TOKEN)).status_code == 401
    assert client.get("/proximity", headers=_auth(new_token)).status_code == 200


def test_live_rotation_clears_lockout(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    for n in range(5):
        client.get("/proximity", headers=_auth(f"bad-{n}"))
    assert client.get("/proximity", headers=_auth("bad-final")).status_code == 429
    state = app.state.auth_state
    assert state.is_locked("testclient") is True
    # External operator rotation (separate object, like the CLI).
    new_token = AuthState(settings=load_auth_settings(sec)).rotate(sec)
    # Reload clears the in-memory lockout: new token 200, bucket cleared.
    resp = client.get("/proximity", headers=_auth(new_token))
    assert resp.status_code == 200
    assert state.is_locked("testclient") is False


# --- 2. SHOULD-03 verify-first-then-lock ---


def test_verify_first_then_lock_correct_clears(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    for n in range(5):
        client.get("/proximity", headers=_auth(f"bad-{n}"))
    assert client.get("/proximity", headers=_auth("bad-final")).status_code == 429
    # Correct token always clears its IP bucket even when previously locked.
    resp = client.get("/proximity", headers=_auth(TOKEN))
    assert resp.status_code == 200
    assert app.state.auth_state.is_locked("testclient") is False


# --- 3. SHOULD-01 empty approval secret fails closed ---


def test_approval_empty_secret_fails_closed(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    # Simulate an operator edit blanking the secret in-memory.
    app.state.auth_state.settings.consent_approval_secret = ""
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"


# --- 4. SHOULD-07 corrupt file aborts typed, file untouched ---


def test_threshold_corrupt_aborts_typed_file_unchanged(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app, raise_server_exceptions=False)
    corrupt = b": : : not yaml: [unclosed\n\t\x00bad"
    sec.write_bytes(corrupt)
    before = sec.read_bytes()
    # Freeze the auth mtime so the request reaches the threshold body itself
    # (otherwise the live-reload in verify would 500 first — still 500 +
    # unchanged, but this isolates the threshold's own typed abort).
    state = app.state.auth_state
    state._security_mtime_ns = sec.stat().st_mtime_ns
    resp = client.post(
        "/proximity/threshold", json={"rssi_near_threshold": -65}, headers=_auth()
    )
    assert resp.status_code == 500
    body = resp.json()
    assert "error" in body and "code" in body["error"] and "message" in body["error"]
    assert sec.read_bytes() == before


def test_rotate_over_corrupt_raises_not_wiping(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    corrupt = b": : : not yaml: [unclosed\n\t\x00bad"
    sec.write_bytes(corrupt)
    before = sec.read_bytes()
    with pytest.raises(RuntimeError, match="corrupt security config"):
        state.rotate(sec)
    assert sec.read_bytes() == before


# --- 5. SHOULD-04/05 DNS-pinned fetch ---


def test_dns_pinned_rebinding_never_connects_private(monkeypatch) -> None:
    calls = {"n": 0}

    def fake_getaddrinfo(host, port, *a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            return list(_PUBLIC)
        return list(_PRIVATE)  # rebinding: connect-time answer is private

    monkeypatch.setattr("socket.getaddrinfo", fake_getaddrinfo)
    pinned = web_search._resolve_public_addrs("example.com", 443)
    assert pinned[0][4][0] == "93.184.216.34"
    with web_search._pinned_getaddrinfo("example.com", pinned):
        second = std_socket.getaddrinfo("example.com", 443)
        assert second[0][4][0] == "93.184.216.34"
        # Other hosts still pass through to the (now-private) resolver.
        other = std_socket.getaddrinfo("other.example", 443)
        assert other[0][4][0] == "10.1.2.3"


class _Resp:
    """Minimal httpx.stream response double with redirect support."""

    def __init__(self, url: str, status: int = 200, location: str | None = None,
                 chunks: list[bytes] | None = None):
        self._url = url
        self.status_code = status
        self.headers = {"location": location} if location else {}
        self._chunks = chunks or [b"<p>hello</p>"]
        self.encoding = "utf-8"

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    @property
    def url(self):
        return httpx.URL(self._url)

    def iter_bytes(self, chunk_size: int = 65536):
        yield from self._chunks


def test_interior_redirect_blocked_without_interior_get(monkeypatch) -> None:
    def fake_getaddrinfo(host, port, *a, **k):
        ip = "10.9.9.9" if host == "private.example" else "93.184.216.34"
        return [(std_socket.AF_INET, std_socket.SOCK_STREAM, 6, "", (ip, 0))]

    requested: list[str] = []

    def fake_stream(method, url, **k):
        requested.append(str(url))
        assert k.get("follow_redirects") is False
        if str(url).startswith("https://public.example"):
            return _Resp(str(url), status=302, location="http://private.example/secret")
        raise AssertionError(f"interior GET must never issue: {url}")

    monkeypatch.setattr("socket.getaddrinfo", fake_getaddrinfo)
    monkeypatch.setattr(httpx, "stream", fake_stream)
    with pytest.raises(ValueError, match="[Nn]on-public|Blocked"):
        web_search.fetch_page_text("https://public.example/start")
    assert requested == ["https://public.example/start"]


def test_hop_limit_exceeded_fails_closed(monkeypatch) -> None:
    monkeypatch.setattr(
        "socket.getaddrinfo", lambda host, port, *a, **k: list(_PUBLIC)
    )
    requested: list[str] = []

    def fake_stream(method, url, **k):
        requested.append(str(url))
        assert k.get("follow_redirects") is False
        n = len(requested)
        return _Resp(str(url), status=302, location=f"https://public.example/hop{n}")

    monkeypatch.setattr(httpx, "stream", fake_stream)
    with pytest.raises(ValueError, match="[Tt]oo many redirects"):
        web_search.fetch_page_text("https://public.example/hop0")
    assert len(requested) == web_search.MAX_REDIRECT_HOPS


# --- 6. SHOULD-06 task_started bound ---


def test_task_started_truncated_200(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")

    def _boom():
        raise RuntimeError("boom-after-started")

    monkeypatch.setattr("buddy_core.orchestrator.load_models_config", _boom)
    long_cmd = "A" * 500
    result = orch.run(long_cmd)
    assert not result.ok
    lines = (tmp_path / "events.jsonl").read_text(encoding="utf-8").splitlines()
    assert lines
    first = json.loads(lines[0])
    assert first["type"] == "task_started"
    assert len(first["text"]) <= 200
    assert first["text"] == long_cmd[:200]


# --- 7. NOTE-02 static fallthrough + generic 500 envelope ---


def test_starlette_fallthrough_static_no_reflection(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")

    @app.get("/_probe_418")
    def _probe():
        raise StarletteHTTPException(status_code=418, detail="secret-probe-xyz")

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get("/_probe_418", headers=_auth())
    assert resp.status_code == 418
    body = resp.json()
    assert body["error"]["code"] == "http_error"
    assert "secret-probe-xyz" not in resp.text


def test_generic_exception_internal_envelope(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec)
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")

    @app.get("/_probe_500")
    def _boom():
        raise RuntimeError("secret-boom-xyz")

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get("/_probe_500", headers=_auth())
    assert resp.status_code == 500
    body = resp.json()
    assert body == {"error": {"code": "internal", "message": "Internal server error"}}
    assert "secret-boom-xyz" not in resp.text
    assert "Traceback" not in resp.text
