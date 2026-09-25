"""Tests for consent-gated MJPEG screen streaming (server/streams.py + routes).

TestClient routing/auth/proximity/consent tests with capture mocked — no real
screenshots, no display needed. Mirrors the fixture style of test_server.py.
"""

import builtins
import io
import json
from datetime import datetime, timezone

import anyio
import httpx
import pytest
import yaml
from fastapi.testclient import TestClient
from PIL import Image

from server import streams
from server.main import create_app

TOKEN = "test-token-123"


def _security(path, mode="lan_only") -> None:
    path.write_text(
        yaml.safe_dump(
            {
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
        ),
        encoding="utf-8",
    )


@pytest.fixture()
def app_lan(tmp_path):
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


@pytest.fixture()
def app_bt(tmp_path):
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_plus_bluetooth")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


def _auth(extra: dict | None = None) -> dict:
    headers = {"Authorization": f"Bearer {TOKEN}"}
    if extra:
        headers.update(extra)
    return headers


def _tiny_jpeg(color: str = "red") -> bytes:
    img = Image.new("RGB", (8, 8), color=color)
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


@pytest.fixture()
def fake_capture(monkeypatch):
    """Mock screen capture (no display) + fast frame rate (no 0.5s sleeps)."""
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "capture_screen_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "TARGET_FPS", 100.0)
    return jpeg


def _request_consent(client: TestClient) -> str:
    resp = client.post("/screen/consent", headers=_auth())
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "pending" and body["consent_id"]
    return body["consent_id"]


def _approve(client: TestClient, consent_id: str) -> None:
    resp = client.post(f"/screen/consent/{consent_id}/approve", headers=_auth())
    assert resp.status_code == 200
    assert resp.json() == {"consent_id": consent_id, "status": "approved"}


async def _aread_frames(resp: httpx.Response, want_soi: int = 2, cap: int = 65536) -> bytes:
    """Read chunks until enough JPEGs arrived. Bounded by anyio.fail_after."""
    body = b""
    async for chunk in resp.aiter_bytes(chunk_size=1024):
        body += chunk
        if body.count(streams.JPEG_SOI) >= want_soi or len(body) > cap:
            break
    return body


# NOTE: httpx's ASGI test transport buffers whole responses, so infinite
# streams are tested via _call_mjpeg_response (direct ASGI) + one real socket.


# --- route: consent gating ---


def test_screen_requires_token(app_lan) -> None:
    client = TestClient(app_lan)
    assert client.get("/screen").status_code == 401
    assert client.post("/screen/consent").status_code == 401


def test_screen_refuses_without_consent(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.get("/screen", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "consent_required"


def test_screen_refuses_unknown_consent(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.get("/screen?consent_id=nope", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "consent_required"


def test_screen_refuses_while_pending(app_lan) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    resp = client.get(f"/screen?consent_id={cid}", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "consent_required"


def test_screen_refuses_when_denied(app_lan) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    denied = client.post(f"/screen/consent/{cid}/deny", headers=_auth())
    assert denied.status_code == 200
    assert denied.json()["status"] == "denied"
    resp = client.get(f"/screen?consent_id={cid}", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "consent_denied"


async def _call_mjpeg_response(response, disconnect_after_frames: int | None = None) -> tuple[int, list[bytes], list[dict]]:
    """Drive an MJPEGResponse through a fake ASGI connection.

    NOTE: httpx's ASGI test transport (0.28+) buffers the WHOLE response body,
    so an infinite MJPEG stream can never be tested through it — the app must
    run to completion first. These tests therefore call the response's ASGI
    interface directly. One real-socket test below covers the true HTTP path.
    """
    scope = {"type": "http", "method": "GET", "path": "/screen"}
    sent: list[dict] = []
    frames_seen = 0

    async def receive() -> dict:
        nonlocal frames_seen
        if disconnect_after_frames is not None and frames_seen >= disconnect_after_frames:
            return {"type": "http.disconnect"}
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message: dict) -> None:
        nonlocal frames_seen
        sent.append(message)
        if message["type"] == "http.response.body" and message.get("body", b""):
            frames_seen += message["body"].count(streams.JPEG_SOI)

    status_holder: list[int] = []

    orig_send = send

    async def tracking_send(message: dict) -> None:
        if message["type"] == "http.response.start":
            status_holder.append(message["status"])
        await orig_send(message)

    with anyio.fail_after(15):
        await response(scope, receive, tracking_send)
    bodies = [m.get("body", b"") for m in sent if m["type"] == "http.response.body"]
    return (status_holder[0] if status_holder else -1), bodies, sent


def _screen_response(app_lan, consent_id: str, jpeg: bytes) -> object:
    """Build the route's MJPEGResponse for an approved grant.

    The route's consent/proximity gating is covered by the TestClient tests
    above; here we test the streaming transport with the same response class
    the route returns.
    """
    manager = app_lan.state.consent_manager
    assert manager.is_approved(consent_id)
    return streams.MJPEGResponse(
        lambda: streams.mjpeg_generator(
            capture_fn=lambda: jpeg, target_fps=1000.0,
            consent_valid=lambda: manager.is_approved(consent_id),
        )
    )


@pytest.mark.asyncio
async def test_approved_stream_returns_multipart_jpeg(app_lan, fake_capture) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    _approve(client, cid)
    status, bodies, sent = await _call_mjpeg_response(
        _screen_response(app_lan, cid, fake_capture), disconnect_after_frames=4
    )
    assert status == 200
    content_types = [m["headers"] for m in sent if m["type"] == "http.response.start"]
    assert any(b"multipart/x-mixed-replace" in v for _, v in content_types[0])
    body = b"".join(bodies)
    assert body.count(b"--frame") >= 2
    assert fake_capture in body  # the exact mocked JPEG bytes are framed
    # The framed payload re-opens as a real JPEG.
    start = body.index(streams.JPEG_SOI)
    end = body.index(b"\xff\xd9", start) + 2
    reopened = Image.open(io.BytesIO(body[start:end]))
    reopened.load()
    assert reopened.size == (8, 8)


@pytest.mark.asyncio
async def test_stream_stops_promptly_on_disconnect(app_lan, fake_capture) -> None:
    """A client that goes away mid-stream must end the response, not hang it."""
    client = TestClient(app_lan)
    cid = _request_consent(client)
    _approve(client, cid)
    status, bodies, _ = await _call_mjpeg_response(
        _screen_response(app_lan, cid, fake_capture), disconnect_after_frames=2
    )
    assert status == 200
    body = b"".join(bodies)
    assert streams.JPEG_SOI in body  # frames flowed before the disconnect


@pytest.mark.asyncio
async def test_stream_over_real_socket(app_lan, fake_capture) -> None:
    """End-to-end /screen over real HTTP: consent-gated MJPEG with live bytes.

    Skipped if uvicorn is unavailable. Guarded by fail_after so a regression
    here fails loudly instead of hanging the suite.
    """
    uvicorn = pytest.importorskip("uvicorn")
    import threading

    config = uvicorn.Config(app_lan, host="127.0.0.1", port=0, log_level="error")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    with anyio.fail_after(20):
        while not server.started:
            await anyio.sleep(0.05)
        port = server.servers[0].sockets[0].getsockname()[1]
        async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}") as http:
            consent = (
                await http.post("/screen/consent", headers=_auth())
            ).json()["consent_id"]
            approve = await http.post(f"/screen/consent/{consent}/approve", headers=_auth())
            assert approve.json()["status"] == "approved"
            async with http.stream(
                "GET", f"/screen?consent_id={consent}", headers=_auth(), timeout=10
            ) as resp:
                assert resp.status_code == 200
                assert "multipart/x-mixed-replace" in resp.headers["content-type"]
                body = await _aread_frames(resp, want_soi=1)
            assert streams.JPEG_SOI in body
    server.should_exit = True
    thread.join(timeout=10)


def _http_scope(path: str, query: bytes = b"", token: str = TOKEN) -> dict:
    """Minimal ASGI HTTP scope for driving a route without a socket."""
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


@pytest.mark.asyncio
async def test_screen_frames_touch_activity(app_lan, fake_capture, monkeypatch) -> None:
    """Decision (2): frame pulls are LAN-surface activity, not idle time.

    Drives the REAL /screen route (auth + consent + heartbeat wrapper) and
    counts touch_activity calls — a passive watcher must not brick mid-session.

    Transport note: the app's HTTP middleware buffers the request body itself,
    so the fake must emulate a real transport — exactly one http.request body,
    then block-until-disconnect (never a stream of http.request messages,
    which real servers never deliver downstream).
    """
    touches: list[str] = []
    import server.main as main_mod

    real_touch = main_mod.touch_activity

    def counting_touch(state) -> None:
        touches.append("frame")
        real_touch(state)

    monkeypatch.setattr("server.main.touch_activity", counting_touch)
    client = TestClient(app_lan)
    cid = _request_consent(client)
    _approve(client, cid)

    gone = anyio.Event()
    sent_body = False
    frames_seen = 0

    async def receive() -> dict:
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()  # _client_gone's 0.05s poll treats the wait as "connected"
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        nonlocal frames_seen
        if message["type"] == "http.response.body" and message.get("body", b""):
            frames_seen += message["body"].count(streams.JPEG_SOI)
            if frames_seen >= 2:
                gone.set()

    scope = _http_scope("/screen", query=f"consent_id={cid}".encode())
    with anyio.fail_after(20):
        await app_lan(scope, receive, send)
    assert frames_seen >= 2
    assert len(touches) >= 2


@pytest.mark.asyncio
async def test_events_keepalive_touches_activity(tmp_path, monkeypatch) -> None:
    """Decision (2): an open /events stream is activity — followers don't brick.

    Real socket (like the MJPEG socket test): only a true HTTP transport
    delivers disconnects the way the app expects, and only a live follow-loop
    can prove the per-poll heartbeat fires. The reader DRAINS continuously —
    breaking out of aiter_bytes() would aclose() the response and drop the
    connection under test (a self-inflicted disconnect that once burned an
    hour of debugging).
    """
    uvicorn = pytest.importorskip("uvicorn")
    import threading

    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    log = tmp_path / "events.jsonl"
    log.write_text(json.dumps({"type": "task_started", "task_id": "hb"}) + "\n", encoding="utf-8")
    app = create_app(security_path=sec, event_log=log)

    touches: list[str] = []
    import server.main as main_mod

    real_touch = main_mod.touch_activity

    def counting_touch(state) -> None:
        touches.append("poll")
        real_touch(state)

    monkeypatch.setattr("server.main.touch_activity", counting_touch)

    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="error")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    received: list[bytes] = []
    replayed = anyio.Event()

    async def drain(port: int) -> None:
        async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}") as http:
            async with http.stream("GET", "/events", headers=_auth(), timeout=10) as resp:
                assert resp.status_code == 200
                async for chunk in resp.aiter_bytes():  # never break: drain till cancelled
                    received.append(chunk)
                    if b"task_started" in b"".join(received):
                        replayed.set()

    with anyio.fail_after(25):
        while not server.started:
            await anyio.sleep(0.05)
        port = server.servers[0].sockets[0].getsockname()[1]
        async with anyio.create_task_group() as tg:
            tg.start_soon(drain, port)
            with anyio.fail_after(10):
                await replayed.wait()  # capped replay still delivers history
            await anyio.sleep(0.2)
            # A line appended mid-stream must reach the attached follower.
            with log.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "tool_call", "tool": "w"}) + "\n")
            await anyio.sleep(1.5)  # ≥2 follow polls at the 0.5s cadence
            tg.cancel_scope.cancel()  # drop the connection → server-side disconnect
    assert len(touches) >= 2
    assert b"tool_call" in b"".join(received)
    server.should_exit = True
    thread.join(timeout=10)


def test_screen_far_mode_forbidden(app_bt, fake_capture) -> None:
    client = TestClient(app_bt)
    resp = client.get("/screen", headers=_auth())  # no X-RSSI -> far
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"
    assert client.post("/screen/consent", headers=_auth()).status_code == 403


def test_consent_endpoints_far_mode_forbidden(app_bt) -> None:
    client = TestClient(app_bt)
    assert client.post("/screen/consent/abc/approve", headers=_auth()).status_code == 403


def test_approve_unknown_consent_404(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.post("/screen/consent/does-not-exist/approve", headers=_auth())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_approve_is_idempotent_and_deny_after_approve_conflicts(app_lan) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    _approve(client, cid)
    again = client.post(f"/screen/consent/{cid}/approve", headers=_auth())
    assert again.status_code == 200
    conflict = client.post(f"/screen/consent/{cid}/deny", headers=_auth())
    assert conflict.status_code == 409


def test_approve_after_deny_conflicts(app_lan) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    client.post(f"/screen/consent/{cid}/deny", headers=_auth())
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_auth())
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "consent_denied"


def test_revoke_unknown_consent_404(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.post("/screen/consent/does-not-exist/revoke", headers=_auth())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_revoke_pending_conflicts(app_lan) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    resp = client.post(f"/screen/consent/{cid}/revoke", headers=_auth())
    assert resp.status_code == 409


def test_revoke_live_grant_stops_stream(app_lan, fake_capture) -> None:
    client = TestClient(app_lan)
    cid = _request_consent(client)
    _approve(client, cid)
    resp = client.post(f"/screen/consent/{cid}/revoke", headers=_auth())
    assert resp.status_code == 200
    assert resp.json()["status"] == "revoked"
    # Idempotent: second revoke is still 200.
    again = client.post(f"/screen/consent/{cid}/revoke", headers=_auth())
    assert again.status_code == 200
    # The revoked grant now fails closed with consent_denied.
    denied = client.get(f"/screen?consent_id={cid}", headers=_auth())
    assert denied.status_code == 403
    assert denied.json()["error"]["code"] == "consent_denied"


# --- unit: ConsentManager ---


def test_consent_manager_lifecycle() -> None:
    mgr = streams.ConsentManager()
    cid = mgr.start_consent_request()
    assert cid and mgr.status_of(cid) is streams.ConsentStatus.PENDING
    assert not mgr.is_approved(cid)
    assert mgr.is_approved("") is False
    assert mgr.is_approved("unknown") is False
    assert mgr.approve("unknown") is False
    assert mgr.approve(cid) is True
    assert mgr.is_approved(cid) is True
    assert mgr.approve(cid) is True  # idempotent
    assert mgr.deny(cid) is False  # approved grants are not revoked by deny


def test_consent_manager_deny_path() -> None:
    mgr = streams.ConsentManager()
    cid = mgr.start_consent_request()
    assert mgr.deny(cid) is True
    assert mgr.status_of(cid) is streams.ConsentStatus.DENIED
    assert mgr.deny(cid) is True  # idempotent
    assert mgr.approve(cid) is False  # denied stays denied


def test_consent_manager_revoke_path() -> None:
    mgr = streams.ConsentManager()
    cid = mgr.start_consent_request()
    assert mgr.revoke(cid) is False  # pending is not a grant — use deny
    assert mgr.revoke("unknown") is False
    assert mgr.approve(cid) is True
    assert mgr.revoke(cid) is True
    assert mgr.status_of(cid) is streams.ConsentStatus.REVOKED
    assert mgr.is_approved(cid) is False  # fail closed after revoke
    assert mgr.revoke(cid) is True  # idempotent
    assert mgr.approve(cid) is False  # revoked stays revoked


def test_consent_manager_expiry() -> None:
    now = [1000.0]
    mgr = streams.ConsentManager(now=lambda: now[0])
    pending = mgr.start_consent_request()
    now[0] += streams.PENDING_TTL_SECONDS + 1
    assert mgr.status_of(pending) is None  # fail closed after TTL
    assert mgr.approve(pending) is False
    live = mgr.start_consent_request()
    assert mgr.approve(live) is True
    now[0] += streams.GRANT_TTL_SECONDS + 1
    assert mgr.is_approved(live) is False
    assert mgr._records == {}  # expired state is purged, stays bounded


# --- unit: MJPEG generator ---


def test_generator_yields_framed_jpeg(monkeypatch) -> None:
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)
    chunks = list(streams.mjpeg_generator(lambda: jpeg, max_frames=3))
    assert len(chunks) == 3
    for chunk in chunks:
        assert chunk.startswith(b"--frame\r\n")
        assert b"Content-Type: image/jpeg" in chunk
        assert chunk.endswith(jpeg + b"\r\n")


def test_generator_skips_non_jpeg_frames(monkeypatch) -> None:
    jpeg = _tiny_jpeg()
    calls = {"n": 0}

    def flaky() -> bytes:
        calls["n"] += 1
        return b"not-a-jpeg" if calls["n"] < 3 else jpeg

    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)
    chunks = list(streams.mjpeg_generator(flaky, max_frames=1))
    assert len(chunks) == 1 and chunks[0].endswith(jpeg + b"\r\n")


def test_generator_stops_after_repeated_failures(monkeypatch) -> None:
    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)
    monkeypatch.setattr(streams, "MAX_CONSECUTIVE_FAILURES", 3)

    def broken() -> bytes:
        raise RuntimeError("no display")

    assert list(streams.mjpeg_generator(broken)) == []


def test_generator_stops_when_consent_lapses(monkeypatch) -> None:
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)
    valid = [True, True, False]

    def consent_valid() -> bool:
        return valid.pop(0) if valid else False

    chunks = list(streams.mjpeg_generator(lambda: jpeg, max_frames=5, consent_valid=consent_valid))
    assert len(chunks) == 2  # stops mid-stream instead of running forever


def test_streaming_path_never_writes_to_disk(monkeypatch) -> None:
    """SECURITY.md: frames must never be persisted — forbid write-mode open()."""
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "TARGET_FPS", 1000.0)
    real_open = builtins.open

    def guarded_open(file, mode="r", *args, **kwargs):
        if any(flag in str(mode) for flag in ("w", "a", "x", "+")):
            raise AssertionError(f"disk write attempted: {file!r} mode={mode!r}")
        return real_open(file, mode, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", guarded_open)
    chunks = list(streams.mjpeg_generator(lambda: jpeg, max_frames=2))
    assert len(chunks) == 2


# --- unit: JPEG encoder (no display needed) ---


def test_encode_jpeg_rgb_roundtrip() -> None:
    rgb = b"\xff\x00\x00" * (4 * 2)  # 4x2 solid red
    jpeg = streams.encode_jpeg_rgb(4, 2, rgb)
    assert jpeg.startswith(streams.JPEG_SOI)
    img = Image.open(io.BytesIO(jpeg))
    img.load()
    assert img.size == (4, 2)


def test_encode_jpeg_rgb_downscales_wide_frames() -> None:
    rgb = b"\x00\x00\x00" * (2000 * 1000)
    jpeg = streams.encode_jpeg_rgb(2000, 1000, rgb, max_width=1000)
    img = Image.open(io.BytesIO(jpeg))
    img.load()
    assert img.size == (1000, 500)


def test_encode_jpeg_rgb_rejects_bad_input() -> None:
    with pytest.raises(ValueError):
        streams.encode_jpeg_rgb(4, 2, b"\x00" * 10)
    with pytest.raises(ValueError):
        streams.encode_jpeg_rgb(0, 2, b"")
