"""Track A1 (auth & session lifetime) tests.

Covers the nine items: stream re-verify, idle flag, /command validation +
semaphore, per-IP lockout, limiter eviction, concurrent writes, corrupt yaml,
rotate script. Fixture style mirrors test_server.py / test_streams.py.
"""

from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

import anyio
import pytest
import yaml
from fastapi.testclient import TestClient
from PIL import Image

from buddy_core import orchestrator
from server import streams
from server.auth import AuthState, _SECURITY_WRITE_LOCK, _persist_auth_file, load_auth_settings
from server.main import (
    ERROR_BUSY,
    MAX_COMMAND_CHARS,
    RateLimiter,
    create_app,
    load_streams_follow_flag,
)

TOKEN = "test-token-123"


def _security(path, mode="lan_only", extra: dict | None = None) -> None:
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
    if extra:
        doc.update(extra)
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


def _auth(extra: dict | None = None) -> dict:
    h = {"Authorization": f"Bearer {TOKEN}"}
    if extra:
        h.update(extra)
    return h


def _tiny_jpeg(color: str = "red") -> bytes:
    img = Image.new("RGB", (8, 8), color=color)
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


def _http_scope(path: str, query: bytes = b"", token: str = TOKEN) -> dict:
    return {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": path,
        "query_string": query,
        "root_path": "",
        "headers": [(b"authorization", f"Bearer {token}".encode())],
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
    }


# --- 1. stream-ends-on-expiry (mock issued_at old) ---


def test_stream_ends_on_expiry_entry(tmp_path) -> None:
    """No stream may outlive the 30-day ceiling — expired token gets 401, never a stream."""
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    data = yaml.safe_load(sec.read_text(encoding="utf-8"))
    data["auth"]["issued_at"] = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    sec.write_text(yaml.safe_dump(data), encoding="utf-8")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    # /events with expired token: scoped 401, not a 200 stream.
    resp = client.get("/events", headers=_auth())
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "token_expired"
    # /screen + /webcam with expired token: 401 before consent gating.
    assert client.get("/screen", headers=_auth()).status_code == 401
    assert client.get("/webcam", headers=_auth()).status_code == 401
    # Wrong token still generic (no oracle).
    resp = client.get("/events", headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


@pytest.mark.asyncio
async def test_stream_stops_midstream_when_ceiling_hits(tmp_path, monkeypatch) -> None:
    """Mid-stream ceiling: a live /screen stream ends promptly when the token expires."""
    sec = tmp_path / "security.yaml"
    # Flag false (default) so idle logic doesn't interfere; ceiling is the trigger.
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "capture_screen_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)
    client = TestClient(app)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/screen/consent/{cid}/approve", headers=_auth()).status_code == 200

    state = app.state.auth_state
    # Expire mid-stream: initial auth sees a live token, ticks see an old one.
    # Flip issued_at after the route's entry check by patching effective time:
    # set settings.issued_at old only after first verify succeeds.
    calls = {"n": 0}
    real_verify = state.verify_with_code

    def flipping_verify(token, client_ip=None):
        calls["n"] += 1
        if calls["n"] <= 1:
            return real_verify(token, client_ip)
        # Subsequent ticks: pretend 31 days passed.
        old_issued = state.settings.issued_at
        old_override = state.issued_at
        state.issued_at = datetime.now(timezone.utc) - timedelta(days=31)
        try:
            return real_verify(token, client_ip)
        finally:
            state.settings.issued_at = old_issued
            state.issued_at = old_override

    monkeypatch.setattr(state, "verify_with_code", flipping_verify)

    gone = anyio.Event()
    sent_body = False
    frames_seen = 0
    returned = False

    async def receive() -> dict:
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        nonlocal frames_seen
        if message["type"] == "http.response.body" and message.get("body", b""):
            frames_seen += message["body"].count(streams.JPEG_SOI)
            if frames_seen >= 10:
                gone.set()

    scope = _http_scope("/screen", query=f"consent_id={cid}".encode())
    with anyio.fail_after(20):
        await app(scope, receive, send)
        returned = True
    # Stream returned (ended) without needing a client disconnect, after at
    # most a couple of frames — it did not run forever past the ceiling.
    assert returned is True
    assert calls["n"] >= 2  # re-verification actually ran each tick
    assert frames_seen <= 2  # stopped promptly instead of streaming 10


# --- 2. idle-not-refreshed-by-streams (flag false) ---


def test_streams_follow_flag_defaults_false(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")  # no flag key
    assert load_streams_follow_flag(sec) is False
    # Explicit true/false round-trip (top-level and auth-nested).
    sec.write_text(yaml.safe_dump({"streams_follow_counts_as_activity": True}), encoding="utf-8")
    assert load_streams_follow_flag(sec) is True
    sec.write_text(yaml.safe_dump({"auth": {"streams_follow_counts_as_activity": True}}), encoding="utf-8")
    assert load_streams_follow_flag(sec) is True
    sec.write_text(yaml.safe_dump({"streams_follow_counts_as_activity": False}), encoding="utf-8")
    assert load_streams_follow_flag(sec) is False


@pytest.mark.asyncio
async def test_idle_not_refreshed_by_streams_when_flag_false(tmp_path, monkeypatch) -> None:
    """Flag false: follow loop does not extend last_activity (idle decays from real requests only)."""
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")  # flagless → default false
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    assert app.state.streams_follow_counts_as_activity is False
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "capture_screen_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)

    touches: list[str] = []
    import server.main as main_mod

    real_touch = main_mod.touch_activity

    def counting_touch(state) -> None:
        touches.append("frame")
        real_touch(state)

    monkeypatch.setattr("server.main.touch_activity", counting_touch)
    client = TestClient(app)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/screen/consent/{cid}/approve", headers=_auth()).status_code == 200

    state = app.state.auth_state
    # Increasing clock: each now() call advances 5s. Initial stream auth stamps
    # near t0; ticks that stamped would push last_activity far ahead. With the
    # flag false the ticks restore, so last_activity stays near the start.
    t0 = datetime.now(timezone.utc)
    counter = [0]

    def fake_now():
        counter[0] += 1
        return t0 + timedelta(seconds=counter[0] * 5)

    state.now = fake_now
    # Seed last_activity via a real request timestamp (first fake_now call).
    state.last_activity = fake_now()
    seed_activity = state.last_activity

    gone = anyio.Event()
    sent_body = False
    frames_seen = 0

    async def receive() -> dict:
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        nonlocal frames_seen
        if message["type"] == "http.response.body" and message.get("body", b""):
            frames_seen += message["body"].count(streams.JPEG_SOI)
            if frames_seen >= 2:
                gone.set()

    scope = _http_scope("/screen", query=f"consent_id={cid}".encode())
    with anyio.fail_after(20):
        await app(scope, receive, send)
    assert frames_seen >= 2
    assert touches == []  # no unconditional heartbeat when flag false
    # Ticks ran (counter advanced far) but last_activity stayed near the
    # stream-entry stamp (initial auth is a real request and may advance once;
    # per-tick refresh would push it far ahead). Idle decayed, not refreshed.
    assert state.last_activity >= seed_activity
    assert state.last_activity <= seed_activity + timedelta(seconds=30)
    assert counter[0] >= 6  # prove ticks actually re-verified (clock advanced)
    latest = t0 + timedelta(seconds=counter[0] * 5)
    assert (latest - state.last_activity) >= timedelta(seconds=15)


# --- 3a. non-string body 400 ---


def test_command_non_string_body_400(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    for bad in (None, 123, 4.5, True, ["hi"], {"nested": 1}):
        resp = client.post("/command", json={"text": bad}, headers=_auth())
        assert resp.status_code == 400, bad
        assert resp.json()["error"]["code"] == "bad_request"
        assert resp.json()["error"] == {"code": "bad_request", "message": resp.json()["error"]["message"]}
    # Missing key also 400 (not 422).
    resp = client.post("/command", json={}, headers=_auth())
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


# --- 3b. overlong 400 ---


def test_command_overlong_400(tmp_path, monkeypatch) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    monkeypatch.setattr(
        orchestrator, "run", lambda *a, **k: orchestrator.TaskResult(ok=True, output="d", task_id="x")
    )
    client = TestClient(app)
    assert MAX_COMMAND_CHARS == 2000
    ok_text = "x" * 2000
    resp = client.post("/command", json={"text": ok_text}, headers=_auth())
    assert resp.status_code == 200
    over = "x" * 2001
    resp = client.post("/command", json={"text": over}, headers=_auth())
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


# --- 3c. semaphore cap: 5th concurrent gets 503 busy ---


def test_command_semaphore_cap_503(tmp_path, monkeypatch) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    entered = []
    entered_event = threading.Event()
    block = threading.Event()

    def blocking_run(text, task_id=None, source="text"):
        entered.append(task_id)
        if len(entered) >= 4:
            entered_event.set()
        assert block.wait(timeout=10), "background did not release"
        return orchestrator.TaskResult(ok=True, output="done", task_id=task_id or "x")

    monkeypatch.setattr(orchestrator, "run", blocking_run)

    results: dict[int, int] = {}
    codes: dict[int, str] = {}

    def do_request(idx: int) -> None:
        c = TestClient(app)
        r = c.post("/command", json={"text": f"task-{idx}"}, headers=_auth())
        results[idx] = r.status_code
        try:
            codes[idx] = r.json().get("error", {}).get("code", r.json().get("status", ""))
        except Exception:
            codes[idx] = ""

    threads = [threading.Thread(target=do_request, args=(i,)) for i in range(4)]
    for t in threads:
        t.start()
    assert entered_event.wait(timeout=10), "4 backgrounds never entered"
    time.sleep(0.2)  # let all 4 hold the semaphore inside background
    # 5th concurrent request must see busy, not queue.
    c5 = TestClient(app)
    r5 = c5.post("/command", json={"text": "task-5"}, headers=_auth())
    assert r5.status_code == 503, r5.text
    assert r5.json()["error"]["code"] == "busy"
    assert r5.json()["error"] == {"code": "busy", "message": r5.json()["error"]["message"]}
    block.set()
    for t in threads:
        t.join(timeout=10)
    assert all(results[i] == 200 for i in range(4)), results


# --- 4. per-IP lockout isolation ---


def test_per_ip_lockout_isolation(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    settings = load_auth_settings(sec)
    state = AuthState(settings=settings)
    # 5 failures from IP-A lock IP-A.
    for _ in range(5):
        assert not state.verify("bad", client_ip="1.1.1.1")
    assert state.is_locked("1.1.1.1") is True
    # IP-B is untouched: wrong-token counter isolated, valid token still works.
    assert state.is_locked("2.2.2.2") is False
    assert state.is_locked() is True  # legacy any-locked view still reports locked
    assert state.verify(settings.token, client_ip="2.2.2.2") is True
    # IP-A stays locked even for the right token.
    assert not state.verify(settings.token, client_ip="1.1.1.1")
    ok, code = state.verify_with_code(settings.token, client_ip="1.1.1.1")
    assert not ok and code == "locked_out"


def test_per_ip_lockout_http_isolation(tmp_path) -> None:
    """HTTP layer keys by client IP: TestClient IP locked, other IP still valid."""
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    for n in range(5):
        client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer bad-{n}"})
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": "Bearer bad-final"})
    assert resp.status_code == 429
    assert resp.json()["error"]["code"] == "locked_out"
    state = app.state.auth_state
    # TestClient's IP is "testclient" — that bucket is locked…
    assert state.is_locked("testclient") is True
    # …but a different IP is not.
    assert state.is_locked("9.9.9.9") is False
    ok, code = state.verify_with_code(TOKEN, client_ip="9.9.9.9")
    assert ok and code == "ok"


# --- 5. limiter eviction bound ---


def test_limiter_eviction_bound() -> None:
    now = [1000.0]
    lim = RateLimiter(per_minute=2, now=lambda: now[0])
    for i in range(50):
        assert lim.allow(f"10.0.0.{i}")[0] is True
    assert len(lim._hits) == 50
    now[0] += 61.0  # all windows stale
    assert lim.allow("new-ip")[0] is True
    # Stale entries pruned inside allow(): bounded, not 51.
    assert len(lim._hits) == 1
    assert list(lim._hits) == ["new-ip"]


# --- 6. concurrent threshold+persist consistency (threads) ---


def test_concurrent_threshold_persist_consistency(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    errors: list[BaseException] = []

    def threshold_job(value: int) -> None:
        try:
            c = TestClient(app)
            r = c.post(
                "/proximity/threshold", json={"rssi_near_threshold": value}, headers=_auth()
            )
            assert r.status_code == 200, (value, r.text)
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    def persist_job(n: int) -> None:
        try:
            data = yaml.safe_load(sec.read_text(encoding="utf-8")) or {}
            # Touch an unrelated key under the shared lock path.
            with _SECURITY_WRITE_LOCK:
                from server.auth import _atomic_write_yaml

                data.setdefault("thread_probe", {})[f"w{n}"] = n
                _atomic_write_yaml(sec, data)
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    with ThreadPoolExecutor(max_workers=10) as ex:
        futs = []
        for i in range(5):
            futs.append(ex.submit(threshold_job, -60 - i))
        for i in range(5):
            futs.append(ex.submit(persist_job, i))
        for f in futs:
            f.result(timeout=15)
    assert errors == []
    on_disk = yaml.safe_load(sec.read_text(encoding="utf-8"))
    assert isinstance(on_disk, dict)
    assert on_disk["auth"]["token"] == TOKEN
    assert on_disk["proximity"]["rssi_near_threshold"] in (-60, -61, -62, -63, -64)
    # File mode stays tight where the platform supports it.
    try:
        mode = stat.S_IMODE(os.stat(sec).st_mode)
        if os.name != "nt":
            assert mode == 0o600
    except OSError:
        pass


# --- 7. corrupt yaml typed error ---


def test_corrupt_security_yaml_typed_error(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    sec.write_text(": : : not yaml: [unclosed\n\t\x00bad", encoding="utf-8")
    with pytest.raises(RuntimeError, match="security.yaml"):
        load_auth_settings(sec)
    try:
        load_auth_settings(sec)
    except RuntimeError as exc:
        assert str(sec) in str(exc)


# --- 8. rotate script round-trip (old 401, new 200) ---


def test_rotate_script_round_trip(tmp_path, monkeypatch) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    log = tmp_path / "events.jsonl"
    app = create_app(security_path=sec, event_log=log)
    client = TestClient(app)
    assert client.get("/proximity", headers=_auth()).status_code == 200

    proc = subprocess.run(
        [sys.executable, "scripts/rotate_token.py", "--security-path", str(sec)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    new_token = proc.stdout.strip().splitlines()[-1].strip()
    assert len(new_token) >= 32
    assert new_token != TOKEN
    # Printed once: exactly one non-empty line.
    non_empty = [ln for ln in proc.stdout.strip().splitlines() if ln.strip()]
    assert len(non_empty) == 1

    on_disk = yaml.safe_load(sec.read_text(encoding="utf-8"))
    assert on_disk["auth"]["token"] == new_token
    assert "issued_at" in on_disk["auth"]

    app2 = create_app(security_path=sec, event_log=log)
    client2 = TestClient(app2)
    assert client2.get("/proximity", headers={"Authorization": f"Bearer {TOKEN}"}).status_code == 401
    assert client2.get("/proximity", headers={"Authorization": f"Bearer {new_token}"}).status_code == 200
