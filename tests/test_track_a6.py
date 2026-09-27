"""Track A6 (backend test-gap closure) tests.

Covers exactly the ten outstanding backend gaps — no production changes:

1. 401 matrix over all 8 consent-mutation routes (no token / wrong token).
2. Webcam deny/revoke 404/409 paths (unknown deny/revoke, approve-after-deny,
   revoke-pending) via the X-Buddy-Approval laptop header.
3. REVOKED -> approve -> 400 "not pending" for BOTH scopes.
4. X-Consent-Id header path for /screen (approved streams 200, unknown 403).
5. capture_screen_jpeg real path with a stubbed `mss` module (numpy BGRX).
6. buddy_core/config.py: _load_yaml FileNotFoundError, security.yaml.example
   fallback, load_apps_config direct call.
7. auth._parse_issued_at unsupported-type branch + issued_at override interplay.
8. web_search SearXNG success path (mocked httpx).
9. Scripts: gen_cert.main() real RSA, pair_device.bind_port() variants,
   rotate_token.main(argv) called directly (it HAS main(argv) — no skip).
10. Wrong-length approval secret -> 403 approval_forbidden, no exception.

Fixture style mirrors tests/test_track_a3.py.
"""

from __future__ import annotations

import importlib.util
import io
from datetime import datetime, timedelta, timezone
from pathlib import Path

import anyio
import pytest
import yaml
from fastapi.testclient import TestClient
from PIL import Image

from server import streams
from server.main import create_app

TOKEN = "test-token-123"
SECRET = "0123456789abcdef" * 4  # 64-hex deterministic
SHORT_SECRET = "short12345"  # 10 chars — wrong length on purpose


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


def _load_script(name: str):
    """Import scripts/<name>.py by path (scripts/ is not a package)."""
    path = Path(__file__).resolve().parent.parent / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"track_a6_{name}", str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def app(tmp_path):
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only", secret=SECRET)
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


# --- 1. 401 matrix: all 8 consent-mutation routes, no token / wrong token ---


_CONSENT_MUTATION_PATHS = [
    "/screen/consent",
    "/screen/consent/no-such-id/approve",
    "/screen/consent/no-such-id/deny",
    "/screen/consent/no-such-id/revoke",
    "/webcam/consent",
    "/webcam/consent/no-such-id/approve",
    "/webcam/consent/no-such-id/deny",
    "/webcam/consent/no-such-id/revoke",
]


@pytest.mark.parametrize("path", _CONSENT_MUTATION_PATHS)
@pytest.mark.parametrize(
    "headers",
    [{}, {"Authorization": "Bearer wrong-token"}],
    ids=["no-token", "wrong-token"],
)
def test_consent_mutation_401_matrix(app, path: str, headers: dict) -> None:
    """Auth runs before consent lookup: unknown ids still 401, never 404/403."""
    client = TestClient(app)
    resp = client.post(path, headers=headers)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


# --- 2. webcam deny/revoke 404/409 ---


def test_webcam_unknown_deny_404(app) -> None:
    client = TestClient(app)
    resp = client.post("/webcam/consent/no-such-id/deny", headers=_approval_headers())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_webcam_unknown_revoke_404(app) -> None:
    client = TestClient(app)
    # Revoke is phone-gated (no approval header) — still 404 for unknown ids.
    resp = client.post("/webcam/consent/no-such-id/revoke", headers=_auth())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_webcam_approve_after_deny_409(app) -> None:
    client = TestClient(app)
    cid = client.post("/webcam/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/webcam/consent/{cid}/deny", headers=_approval_headers()).status_code == 200
    resp = client.post(f"/webcam/consent/{cid}/approve", headers=_approval_headers())
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "consent_denied"


def test_webcam_revoke_pending_409(app) -> None:
    client = TestClient(app)
    cid = client.post("/webcam/consent", headers=_auth()).json()["consent_id"]
    # Revocation is strictly a grant operation — pending requests use deny.
    resp = client.post(f"/webcam/consent/{cid}/revoke", headers=_auth())
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "conflict"


# --- 3. REVOKED -> approve -> 400 "not pending", both scopes ---


@pytest.mark.parametrize("scope", ["screen", "webcam"])
def test_revoked_approve_is_400_not_pending(app, scope: str) -> None:
    client = TestClient(app)
    cid = client.post(f"/{scope}/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/{scope}/consent/{cid}/approve", headers=_approval_headers()).status_code == 200
    assert client.post(f"/{scope}/consent/{cid}/revoke", headers=_auth()).status_code == 200
    resp = client.post(f"/{scope}/consent/{cid}/approve", headers=_approval_headers())
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


# --- 4. X-Consent-Id header path for /screen ---


def test_screen_unknown_consent_via_header_consent_required(app) -> None:
    client = TestClient(app)
    resp = client.get("/screen", headers=_auth({"X-Consent-Id": "no-such-id"}))
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "consent_required"


@pytest.mark.asyncio
async def test_screen_approved_grant_via_header_streams_200(tmp_path, monkeypatch) -> None:
    """Drive the REAL /screen route over ASGI with the grant as X-Consent-Id.

    TestClient cannot hold an infinite MJPEG stream (it buffers the whole
    body), so this uses the direct-ASGI pattern from test_streams.py:
    exactly one http.request body, then block-until-disconnect.
    """
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only", streams_block={"target_fps": 50.0})
    fast_app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    jpeg = _tiny_jpeg()
    monkeypatch.setattr(streams, "capture_screen_jpeg", lambda *a, **k: jpeg)
    monkeypatch.setattr(streams, "capture_screen_frame", lambda *a, **k: jpeg)
    client = TestClient(fast_app)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    assert client.post(f"/screen/consent/{cid}/approve", headers=_approval_headers()).status_code == 200

    statuses: list[int] = []
    frames = [0]
    gone = anyio.Event()
    sent_body = [False]

    async def receive() -> dict:
        if not sent_body[0]:
            sent_body[0] = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()  # the 0.05s poll treats the wait as "connected"
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        if message["type"] == "http.response.start":
            statuses.append(message["status"])
        if message["type"] == "http.response.body" and message.get("body", b""):
            frames[0] += message["body"].count(streams.JPEG_SOI)
            if frames[0] >= 2:
                gone.set()

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/screen",
        "query_string": b"",
        "root_path": "",
        "headers": [
            (b"authorization", f"Bearer {TOKEN}".encode()),
            (b"x-consent-id", cid.encode()),
        ],
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
    }
    with anyio.fail_after(20):
        await fast_app(scope, receive, send)
    assert statuses == [200]
    assert frames[0] >= 2


# --- 5. capture_screen_jpeg real path with stubbed mss (numpy BGRX) ---


def test_capture_screen_jpeg_real_path_with_stub_mss(monkeypatch) -> None:
    """Exercise the real function: import guard, monitors[1], BGRX decode, resize."""
    import sys
    import types

    import numpy as np

    W, H = 2000, 100  # wider than max_width=1280 -> resize path
    px = np.zeros((H, W, 4), dtype=np.uint8)
    px[..., 0] = 10  # B
    px[..., 1] = 20  # G
    px[..., 2] = 200  # R
    grabbed: dict = {}
    MON0 = {"left": 0, "top": 0, "width": 1, "height": 1}  # virtual screen
    MON1 = {"left": 0, "top": 0, "width": W, "height": H}  # primary display

    class _Shot:
        width = W
        height = H
        raw = px  # bytes(shot.raw) yields the raw BGRX buffer

    class _FakeSCT:
        monitors = [MON0, MON1]

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def grab(self, monitor):
            grabbed["monitor"] = monitor
            return _Shot()

    fake_mss = types.ModuleType("mss")
    fake_mss.mss = _FakeSCT
    monkeypatch.setitem(sys.modules, "mss", fake_mss)

    out = streams.capture_screen_jpeg()
    assert out.startswith(streams.JPEG_SOI)
    assert grabbed.get("monitor") is MON1  # primary display, not the virtual screen
    img = Image.open(io.BytesIO(out))
    img.load()
    assert img.size == (1280, round(H * 1280 / W))  # aspect-preserved downscale


# --- 6. buddy_core/config.py: _load_yaml + security example fallback + apps ---


def test_load_yaml_missing_required_raises(monkeypatch, tmp_path) -> None:
    import buddy_core.config as cfg

    monkeypatch.setattr(cfg, "CONFIG_DIR", tmp_path)
    with pytest.raises(FileNotFoundError):
        cfg._load_yaml("models.yaml")


def test_security_yaml_example_fallback(monkeypatch, tmp_path) -> None:
    """Absent security.yaml falls back to security.yaml.example (config.py:24-27)."""
    import buddy_core.config as cfg

    monkeypatch.setattr(cfg, "CONFIG_DIR", tmp_path)
    (tmp_path / "security.yaml.example").write_text(
        yaml.safe_dump({"auth": {"token": "from-example"}}), encoding="utf-8"
    )
    assert cfg._load_yaml("security.yaml") == {"auth": {"token": "from-example"}}


def test_security_yaml_absent_no_example_empty(monkeypatch, tmp_path) -> None:
    import buddy_core.config as cfg

    monkeypatch.setattr(cfg, "CONFIG_DIR", tmp_path)
    assert cfg._load_yaml("security.yaml") == {}


def test_load_apps_config_direct(monkeypatch, tmp_path) -> None:
    import buddy_core.config as cfg

    monkeypatch.setattr(cfg, "CONFIG_DIR", tmp_path)
    (tmp_path / "apps.yaml").write_text(
        yaml.safe_dump(
            {
                "apps": {
                    "code": {"display": "VS Code", "launcher": "code"},
                    "skipme": {"display": "No launcher here"},
                    "strange": "not-a-dict",
                }
            }
        ),
        encoding="utf-8",
    )
    apps_cfg = cfg.load_apps_config()
    assert apps_cfg.apps["code"].launcher == "code"
    assert apps_cfg.apps["code"].display == "VS Code"
    assert "skipme" not in apps_cfg.apps
    assert "strange" not in apps_cfg.apps
    # Explicit-path call resolves by basename against CONFIG_DIR.
    again = cfg.load_apps_config(tmp_path / "apps.yaml")
    assert again.apps["code"].display == "VS Code"


# --- 7. auth._parse_issued_at unsupported type + issued_at override interplay ---


def test_parse_issued_at_unsupported_type() -> None:
    from server.auth import _parse_issued_at

    with pytest.raises(ValueError, match="unsupported type"):
        _parse_issued_at(12345)
    with pytest.raises(ValueError, match="unsupported type"):
        _parse_issued_at(["2024-01-01"])


def test_issued_at_override_interplay() -> None:
    """AuthState.issued_at overrides settings.issued_at — and moves the ceiling."""
    from server.auth import AuthSettings, AuthState

    now = datetime.now(timezone.utc)
    settings = AuthSettings(token="t", issued_at=now - timedelta(days=31))
    # No override: falls back to settings (31 days old -> expired under default 30).
    assert AuthState(settings=settings).effective_issued_at() == settings.issued_at
    assert AuthState(settings=settings).is_absolute_expired() is True
    # Override wins: a 1-day-old test issuance is NOT expired on the same settings.
    override = now - timedelta(days=1)
    state = AuthState(settings=settings, issued_at=override)
    assert state.effective_issued_at() == override
    assert state.is_absolute_expired() is False


# --- 8. web_search SearXNG success path ---


def test_searxng_success_path(monkeypatch) -> None:
    import httpx
    import json as _json
    import socket as _socket

    from buddy_core.config import WebSearchConfig
    from buddy_core.tools import web_search

    payload = {
        "results": [
            {"title": "First", "url": "https://example.com/1", "content": "snippet one"},
            {"title": "Second", "url": "https://example.com/2", "content": "snippet two"},
            {"title": "Third", "url": "https://example.com/3", "content": "snippet three"},
        ]
    }
    seen: dict = {}

    class _Resp:
        """Minimal httpx.stream double for the SearXNG JSON payload."""

        def __init__(self, url: str):
            self._url = url

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def raise_for_status(self) -> None:
            pass

        @property
        def url(self):
            return httpx.URL(self._url)

        @property
        def encoding(self):
            return "utf-8"

        def iter_bytes(self, chunk_size: int = 65536):
            yield _json.dumps(payload).encode("utf-8")

    def fake_stream(method, url, **kwargs):
        seen["url"] = str(url)
        seen["params"] = kwargs.get("params")
        assert kwargs.get("follow_redirects") is False
        return _Resp(str(url))

    def fake_getaddrinfo(host, port, *args, **kwargs):
        return [(_socket.AF_INET, _socket.SOCK_STREAM, 6, "", ("93.184.216.34", 0))]

    monkeypatch.setattr(httpx, "stream", fake_stream)
    monkeypatch.setattr("socket.getaddrinfo", fake_getaddrinfo)
    hits = web_search.search(
        "hello",
        WebSearchConfig(backend="searxng", searxng_url="https://searx.example/"),
        max_results=2,
    )
    assert seen["url"] == "https://searx.example/search"
    assert seen["params"] == {"q": "hello", "format": "json"}
    assert len(hits) == 2  # honours max_results slicing
    assert hits[0].title == "First"
    assert hits[0].url == "https://example.com/1"
    assert hits[0].snippet == "snippet one"


# --- 9. scripts: gen_cert / pair_device.bind_port / rotate_token.main ---


def test_gen_cert_main_real_rsa(tmp_path, capsys) -> None:
    """Real 2048-bit RSA into a tmp out-dir: pem files, parseable cert, matching fp."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization

    mod = _load_script("gen_cert")
    assert mod.main(["--out-dir", str(tmp_path)]) == 0
    cert_pem = tmp_path / "dev-cert.pem"
    key_pem = tmp_path / "dev-key.pem"
    assert cert_pem.exists() and key_pem.exists()

    cert = x509.load_pem_x509_certificate(cert_pem.read_bytes())
    assert cert.not_valid_after_utc > cert.not_valid_before_utc
    fingerprint = cert.fingerprint(hashes.SHA256()).hex()
    assert len(fingerprint) == 64
    printed = capsys.readouterr().out
    assert fingerprint in printed  # printed pin matches the real cert

    key = serialization.load_pem_private_key(key_pem.read_bytes(), password=None)
    assert key.key_size == 2048


def _write_repo_security_yaml(root: Path, doc: dict) -> None:
    cfgdir = root / "config"
    cfgdir.mkdir(parents=True, exist_ok=True)
    (cfgdir / "security.yaml").write_text(yaml.safe_dump(doc), encoding="utf-8")


def test_bind_port_default_without_file(monkeypatch, tmp_path) -> None:
    monkeypatch.chdir(tmp_path)
    assert _load_script("pair_device").bind_port() == 8443


def test_bind_port_custom(monkeypatch, tmp_path) -> None:
    monkeypatch.chdir(tmp_path)
    _write_repo_security_yaml(tmp_path, {"network": {"bind_port": 9999}})
    assert _load_script("pair_device").bind_port() == 9999


def test_bind_port_missing_network_key(monkeypatch, tmp_path) -> None:
    monkeypatch.chdir(tmp_path)
    _write_repo_security_yaml(tmp_path, {"auth": {"token": "x"}})
    assert _load_script("pair_device").bind_port() == 8443


@pytest.mark.parametrize("bad", [0, -1, 65536, 99999, "nonsense", None])
def test_bind_port_clamp_and_garbage(monkeypatch, tmp_path, bad) -> None:
    """Out-of-range / unparseable ports fall back to DEFAULT_PORT, never raise."""
    monkeypatch.chdir(tmp_path)
    _write_repo_security_yaml(tmp_path, {"network": {"bind_port": bad}})
    assert _load_script("pair_device").bind_port() == 8443


def test_bind_port_bad_yaml(monkeypatch, tmp_path) -> None:
    monkeypatch.chdir(tmp_path)
    cfgdir = tmp_path / "config"
    cfgdir.mkdir(parents=True, exist_ok=True)
    (cfgdir / "security.yaml").write_text("{{{ not yaml", encoding="utf-8")
    assert _load_script("pair_device").bind_port() == 8443


def test_rotate_token_main_direct(tmp_path, capsys) -> None:
    """rotate_token HAS main(argv) — call it directly (no subprocess in tests)."""
    mod = _load_script("rotate_token")
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    assert mod.main(["--security-path", str(sec)]) == 0
    new_token = capsys.readouterr().out.strip().splitlines()[-1].strip()
    assert new_token and new_token != TOKEN
    assert len(new_token) >= 32
    assert yaml.safe_load(sec.read_text(encoding="utf-8"))["auth"]["token"] == new_token
    # Round-trip: old token 401s, new token 200s on a fresh app.
    log = tmp_path / "events.jsonl"
    assert (
        TestClient(create_app(security_path=sec, event_log=log)).get(
            "/proximity", headers={"Authorization": f"Bearer {TOKEN}"}
        ).status_code
        == 401
    )
    assert (
        TestClient(create_app(security_path=sec, event_log=log)).get(
            "/proximity", headers={"Authorization": f"Bearer {new_token}"}
        ).status_code
        == 200
    )


# --- 10. wrong-length approval secret -> 403 approval_forbidden, no exception ---


@pytest.mark.parametrize("action", ["approve", "deny"])
def test_short_provided_secret_403_no_exception(app, action: str) -> None:
    """A 10-char header vs the 64-hex configured secret: compare_digest is
    False (not an exception) -> 403 approval_forbidden JSON, never a 500."""
    client = TestClient(app)  # raise_server_exceptions=True: a raise would fail the test
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(f"/screen/consent/{cid}/{action}", headers=_auth({"X-Buddy-Approval": SHORT_SECRET}))
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"


def test_short_configured_secret_mismatch_403(tmp_path) -> None:
    """Configured secret itself is 10 chars; a non-matching value still 403s cleanly."""
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only", secret=SHORT_SECRET)
    short_app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(short_app)
    cid = client.post("/screen/consent", headers=_auth()).json()["consent_id"]
    resp = client.post(
        f"/screen/consent/{cid}/approve", headers=_auth({"X-Buddy-Approval": "different!0"})
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"
