"""Track A3 (consent model rework — BREAKING) tests.

Covers: laptop-only approval (loopback OR X-Buddy-Approval), stream caps
(1 per grant + 4 per IP with 429 stream_limit), single handle lifecycle,
streams: config overrides, cross-scope isolation. Fixture style mirrors
test_streams.py / test_track_a1.py.
"""

from __future__ import annotations

import io
import secrets
from contextlib import contextmanager
from datetime import datetime, timezone

import anyio
import pytest
import yaml
from fastapi.testclient import TestClient
from PIL import Image

from server import streams
from server.auth import generate_approval_secret
from server.main import _is_loopback, create_app, load_streams_config

TOKEN = "test-token-123"
SECRET = "0123456789abcdef" * 4  # 64-hex deterministic
WRONG_SECRET = "ff" * 32


def _security(path, mode="lan_only", secret=SECRET, streams_block=None) -> None:
    doc = {
        "auth": {
            "token": TOKEN,
            "consent_approval_secret": secret,
            "max_failed_attempts": 5,
            "lockout_minutes": 15,
            "idle_timeout_minutes": 60,
            "token_absolute_max_age_days": 30,
            "issued_at": datetime.now(timezone.utc).isoformat(),
        },
        "proximity": {"mode": mode, "rssi_near_threshold": -60, "fail_mode": "far"},
    }
    if streams_block is not None:
        doc["streams"] = streams_block
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


def _auth(extra: dict | None = None) -> dict:
    h = {"Authorization": f"Bearer {TOKEN}"}
    if extra:
        h.update(extra)
    return h


def _approval_headers(secret: str = SECRET) -> dict:
    return _auth({"X-Buddy-Approval": secret})


def _tiny_jpeg(color: str = "red") -> bytes:
    img = Image.new("RGB", (8, 8), color=color)
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


@pytest.fixture()
def app_secret(tmp_path):
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only", secret=SECRET)
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


# --- 1. approval gating ---


def test_phone_token_approve_forbidden(app_secret) -> None:
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"


def test_phone_token_deny_forbidden(app_secret) -> None:
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/deny", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"


def test_webcam_phone_token_approve_deny_forbidden(app_secret) -> None:
    client = TestClient(app_secret)
    cid = client.post("/webcam/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/webcam/consent/{cid}/approve", headers=_auth()).json()["error"]["code"] == "approval_forbidden"
    assert client.post(f"/webcam/consent/{cid}/approve", headers=_auth()).status_code == 403
    assert client.post(f"/webcam/consent/{cid}/deny", headers=_auth()).status_code == 403
    assert client.post(f"/webcam/consent/{cid}/deny", headers=_auth()).json()["error"]["code"] == "approval_forbidden"


def test_wrong_secret_403(app_secret) -> None:
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_approval_headers(WRONG_SECRET))
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"
    # Deny with wrong secret also 403.
    cid2 = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp2 = client.post(f"/screen/consent/{cid2}/deny", headers=_approval_headers(WRONG_SECRET))
    assert resp2.status_code == 403
    assert resp2.json()["error"]["code"] == "approval_forbidden"


def test_correct_secret_works(app_secret) -> None:
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_approval_headers(SECRET))
    assert resp.status_code == 200
    assert resp.json() == {"consent_id": cid, "status": "approved"}
    # Deny with correct secret works on a fresh pending.
    cid2 = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    deny = client.post(f"/screen/consent/{cid2}/deny", headers=_approval_headers(SECRET))
    assert deny.status_code == 200
    assert deny.json()["status"] == "denied"
    # Webcam too.
    wcid = client.post("/webcam/consent", headers=_auth()).json()["consent_id"]
    wapp = client.post(f"/webcam/consent/{wcid}/approve", headers=_approval_headers(SECRET))
    assert wapp.status_code == 200


def test_loopback_approve_works(app_secret, monkeypatch) -> None:
    import server.main as main_mod

    monkeypatch.setattr(main_mod, "_client_ip", lambda req: "127.0.0.1")
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_auth())
    assert resp.status_code == 200
    assert resp.json()["status"] == "approved"


def test_loopback_ipv6_and_helper() -> None:
    assert _is_loopback("127.0.0.1") is True
    assert _is_loopback("::1") is True
    assert _is_loopback("testclient") is False
    assert _is_loopback("192.168.1.10") is False
    assert _is_loopback("") is False
    assert _is_loopback(None) is False


def test_generate_approval_secret_is_64hex() -> None:
    s = generate_approval_secret()
    assert len(s) == 64
    int(s, 16)  # raises if not hex


def test_consent_creation_stays_phone_gated(app_secret) -> None:
    # Creation needs only phone-token + near — no secret header.
    client = TestClient(app_secret)
    resp = client.post("/screen/consent", headers=_auth())
    assert resp.status_code == 200
    assert resp.json()["status"] == "pending"
    resp2 = client.post("/webcam/consent", headers=_auth())
    assert resp2.status_code == 200


def test_revoke_still_phone_gated(app_secret) -> None:
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/screen/consent/{cid}/approve", headers=_approval_headers(SECRET)).status_code == 200
    # Revoke with phone token only (no secret, non-loopback) must still work.
    rev = client.post(f"/screen/consent/{cid}/revoke", headers=_auth())
    assert rev.status_code == 200
    assert rev.json()["status"] == "revoked"
    # Webcam revoke too.
    wcid = client.post("/webcam/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/webcam/consent/{wcid}/approve", headers=_approval_headers(SECRET)).status_code == 200
    wrev = client.post(f"/webcam/consent/{wcid}/revoke", headers=_auth())
    assert wrev.status_code == 200


# --- 2. stream caps ---


def test_second_concurrent_stream_same_grant_429(app_secret, monkeypatch) -> None:
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "capture_screen_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "capture_screen_frame", lambda *a, **k: jpeg)
    client = TestClient(app_secret)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/screen/consent/{cid}/approve", headers=_approval_headers(SECRET)).status_code == 200
    mgr = app_secret.state.consent_manager
    # Simulate first live stream holding its slot (TestClient IP is "testclient").
    assert mgr.try_acquire_stream(cid, "testclient") is True
    try:
        resp = client.get(f"/screen?consent_id={cid}", headers=_auth())
        assert resp.status_code == 429
        assert resp.json()["error"]["code"] == "stream_limit"
        assert "Retry-After" in resp.headers
    finally:
        mgr.release_stream(cid, "testclient")


def test_ip_cap_429(app_secret, monkeypatch) -> None:
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "capture_screen_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "capture_screen_frame", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "capture_webcam_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "capture_webcam_frame", lambda *a, **k: jpeg)
    client = TestClient(app_secret)
    mgr = app_secret.state.consent_manager
    cids: list[str] = []
    for _ in range(4):
        cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
        assert client.post(f"/screen/consent/{cid}/approve", headers=_approval_headers(SECRET)).status_code == 200
        cids.append(cid)
        assert mgr.try_acquire_stream(cid, "testclient") is True
    try:
        # 5th grant, same IP — per-grant passes (fresh grant) but per-IP caps.
        fifth = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
        assert client.post(f"/screen/consent/{fifth}/approve", headers=_approval_headers(SECRET)).status_code == 200
        resp = client.get(f"/screen?consent_id={fifth}", headers=_auth())
        assert resp.status_code == 429
        assert resp.json()["error"]["code"] == "stream_limit"
        assert "Retry-After" in resp.headers
    finally:
        for cid in cids:
            mgr.release_stream(cid, "testclient")


def test_manager_acquire_release_counts() -> None:
    mgr = streams.ConsentManager()
    assert mgr.try_acquire_stream("g1", "1.1.1.1") is True
    # Second on same grant fails (1-per-grant).
    assert mgr.try_acquire_stream("g1", "1.1.1.1") is False
    assert mgr.live_count_for_grant("g1") == 1
    # Fill IP cap with distinct grants.
    for i in range(2, 5):
        assert mgr.try_acquire_stream(f"g{i}", "1.1.1.1") is True
    assert mgr.live_count_for_ip("1.1.1.1") == 4
    assert mgr.try_acquire_stream("g5", "1.1.1.1") is False
    # Different IP still has budget.
    assert mgr.try_acquire_stream("g5", "2.2.2.2") is True
    mgr.release_stream("g1", "1.1.1.1")
    assert mgr.live_count_for_grant("g1") == 0
    assert mgr.try_acquire_stream("g6", "1.1.1.1") is True
    # Release is idempotent, never negative.
    mgr.release_stream("unknown", "9.9.9.9")
    mgr.release_stream("g5", "1.1.1.1")
    mgr.release_stream("g5", "1.1.1.1")
    assert mgr.live_count_for_grant("g5") == 0 or mgr.live_count_for_grant("g5") >= 0


# --- 3. handle lifecycle ---


async def _call_mjpeg_response(response, disconnect_after_frames: int | None = None):
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

    async def tracking_send(message: dict) -> None:
        if message["type"] == "http.response.start":
            status_holder.append(message["status"])
        await send(message)

    with anyio.fail_after(15):
        await response(scope, receive, tracking_send)
    bodies = [m.get("body", b"") for m in sent if m["type"] == "http.response.body"]
    return (status_holder[0] if status_holder else -1), bodies


@pytest.mark.asyncio
async def test_handle_released_on_disconnect() -> None:
    jpeg = _tiny_jpeg()
    counts = {"open": 0, "close": 0}

    @contextmanager
    def counting_factory():
        counts["open"] += 1
        try:
            yield object()
        finally:
            counts["close"] += 1

    def capture_with_handle(handle) -> bytes:
        assert handle is not None
        return jpeg

    resp = streams.MJPEGResponse(
        lambda: streams.mjpeg_generator(
            capture_fn=capture_with_handle,
            target_fps=1000.0,
            handle_factory=counting_factory,
            consent_valid=lambda: True,
        )
    )
    status, bodies = await _call_mjpeg_response(resp, disconnect_after_frames=2)
    assert status == 200
    body = b"".join(bodies)
    assert streams.JPEG_SOI in body
    assert counts["open"] == 1
    assert counts["close"] == 1  # disconnect ran __exit__


@pytest.mark.asyncio
async def test_handle_released_on_consent_lapse() -> None:
    jpeg = _tiny_jpeg()
    counts = {"open": 0, "close": 0}

    @contextmanager
    def counting_factory():
        counts["open"] += 1
        try:
            yield object()
        finally:
            counts["close"] += 1

    valid = [True, True, False]

    def consent_valid() -> bool:
        return valid.pop(0) if valid else False

    gen = streams.mjpeg_generator(
        capture_fn=lambda handle: jpeg,
        target_fps=1000.0,
        handle_factory=counting_factory,
        consent_valid=consent_valid,
    )
    chunks = list(gen)
    assert len(chunks) == 2
    assert counts["open"] == 1
    assert counts["close"] == 1


# --- 4. streams config overrides ---


def test_config_overrides_honored(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(
        sec,
        "lan_only",
        secret=SECRET,
        streams_block={
            "target_fps": 7.5,
            "max_consecutive_failures": 4,
            "pending_ttl_seconds": 11,
            "grant_ttl_seconds": 22,
            "max_consent_records": 33,
        },
    )
    cfg = load_streams_config(sec)
    assert cfg["target_fps"] == 7.5
    assert cfg["max_consecutive_failures"] == 4
    assert cfg["pending_ttl_seconds"] == 11
    assert cfg["grant_ttl_seconds"] == 22
    assert cfg["max_consent_records"] == 33
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    assert app.state.streams_config["target_fps"] == 7.5
    mgr = app.state.consent_manager
    assert mgr.pending_ttl == 11
    assert mgr.grant_ttl == 22
    assert mgr.max_records == 33
    assert mgr.target_fps == 7.5
    assert mgr.max_consecutive_failures == 4
    # TTL actually honored: pending expires after 11s.
    now = [1000.0]
    mgr2 = streams.ConsentManager(pending_ttl=11, grant_ttl=22, now=lambda: now[0])
    cid = mgr2.start_consent_request()
    now[0] += 12
    assert mgr2.status_of(cid) is None


def test_config_defaults_when_block_missing(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only", secret=SECRET)
    cfg = load_streams_config(sec)
    assert cfg["target_fps"] == streams.TARGET_FPS
    assert cfg["max_consecutive_failures"] == streams.MAX_CONSECUTIVE_FAILURES
    assert cfg["pending_ttl_seconds"] == streams.PENDING_TTL_SECONDS
    assert cfg["grant_ttl_seconds"] == streams.GRANT_TTL_SECONDS
    assert cfg["max_consent_records"] == streams.MAX_CONSENT_RECORDS


# --- 5. cross-scope isolation preserved ---


def test_cross_scope_isolation_preserved(app_secret) -> None:
    client = TestClient(app_secret)
    screen_cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/screen/consent/{screen_cid}/approve", headers=_approval_headers(SECRET)).status_code == 200
    webcam_cid = client.post("/webcam/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/webcam/consent/{webcam_cid}/approve", headers=_approval_headers(SECRET)).status_code == 200
    assert client.get(f"/webcam?consent_id={screen_cid}", headers=_auth()).json()["error"]["code"] == "consent_required"
    assert client.get(f"/screen?consent_id={webcam_cid}", headers=_auth()).json()["error"]["code"] == "consent_required"


# --- 6. legacy backfill (fail closed) ---


def test_legacy_file_without_secret_gets_backfilled_and_gate_armed(tmp_path) -> None:
    """Pre-A3 files gain a persisted secret on load; the gate stays armed."""
    from server.auth import load_auth_settings

    sec = tmp_path / "security.yaml"
    sec.write_text(
        yaml.safe_dump(
            {
                "auth": {
                    "token": TOKEN,
                    "issued_at": datetime.now(timezone.utc).isoformat(),
                }
            }
        ),
        encoding="utf-8",
    )
    settings = load_auth_settings(sec)
    assert len(settings.consent_approval_secret) == 64
    int(settings.consent_approval_secret, 16)  # valid hex
    # Persisted: a second load reads the same secret (no rotation on boot).
    assert load_auth_settings(sec).consent_approval_secret == settings.consent_approval_secret
    # Gate armed: phone-token-only approval is forbidden on this legacy file.
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/approve", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"
