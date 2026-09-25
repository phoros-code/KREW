"""FastAPI control server — endpoints exactly per API.md.

- GET  /health   — unauthenticated, minimal ({status: ok} only)
- POST /command  — near only, queues orchestrator.run() in the background
- GET  /events   — near or far, SSE tail of logs/events.jsonl
- GET  /screen   — near only + explicit consent grant, MJPEG stream
- POST /screen/consent (+ /{id}/approve, /{id}/deny, /{id}/revoke) — consent flow, near only

Every route except /health requires the bearer dependency from server.auth.
Proximity failures default to FAR (fail closed — SECURITY.md).
"""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from pathlib import Path
from typing import Callable, Iterator

import yaml
from fastapi import BackgroundTasks, Depends, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.types import Receive, Scope, Send

from buddy_core.config import CONFIG_DIR
from server import streams
from server.auth import SECURITY_PATH, AuthState, load_auth_settings

ERROR_UNAUTHORIZED = {"error": {"code": "unauthorized", "message": "Invalid or expired token"}}
ERROR_TOKEN_EXPIRED = {
    "error": {"code": "token_expired", "message": "Pairing token exceeded its absolute age — re-pair from the laptop"}
}
ERROR_FORBIDDEN = {"error": {"code": "forbidden", "message": "Requires near proximity"}}
ERROR_LOCKED = {"error": {"code": "locked_out", "message": "Too many failed attempts — try again later"}}
ERROR_CONSENT_REQUIRED = {
    "error": {"code": "consent_required", "message": "Screen sharing requires explicit on-device consent"}
}
ERROR_CONSENT_DENIED = {
    "error": {"code": "consent_denied", "message": "Screen share request was denied"}
}
ERROR_CONSENT_NOT_FOUND = {"error": {"code": "not_found", "message": "Unknown consent request"}}
ERROR_RATE_LIMITED = {
    "error": {"code": "rate_limited", "message": "Too many requests — slow down and try again shortly"}
}

# Documented default for network.rate_limit_per_minute (CONFIG.md).
# Missing/unparseable config falls back here — never to "unlimited".
DEFAULT_RATE_LIMIT_PER_MINUTE = 60


def load_proximity_config(path: str | Path = SECURITY_PATH) -> dict:
    path = Path(path)
    src = path if path.exists() else CONFIG_DIR / "security.yaml.example"
    if not src.exists():
        return {"mode": "lan_only", "rssi_near_threshold": -60, "fail_mode": "far"}
    data = yaml.safe_load(src.read_text(encoding="utf-8")) or {}
    prox = data.get("proximity", {})
    return {
        "mode": prox.get("mode", "lan_only"),
        "rssi_near_threshold": prox.get("rssi_near_threshold", -60),
        "fail_mode": prox.get("fail_mode", "far"),
    }


def get_proximity(prox_cfg: dict, x_rssi: float | None = None) -> str:
    """Return 'near' or 'far'. Undeterminable input ALWAYS yields 'far'."""
    if prox_cfg.get("mode") == "lan_only":
        return "near"  # arrival over the LAN-bound socket is the proximity signal
    if x_rssi is None:
        return "far"
    try:
        return "near" if float(x_rssi) >= float(prox_cfg.get("rssi_near_threshold", -60)) else "far"
    except (TypeError, ValueError):
        return "far"


def load_network_config(path: str | Path = SECURITY_PATH) -> dict:
    """Read the network section. Missing/garbage falls back to the default cap."""
    path = Path(path)
    src = path if path.exists() else CONFIG_DIR / "security.yaml.example"
    per_minute = DEFAULT_RATE_LIMIT_PER_MINUTE
    if src.exists():
        try:
            data = yaml.safe_load(src.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            data = {}
        net = data.get("network", {}) or {}
        try:
            per_minute = int(net.get("rate_limit_per_minute", per_minute))
        except (TypeError, ValueError):
            per_minute = DEFAULT_RATE_LIMIT_PER_MINUTE
        if per_minute < 1:
            per_minute = DEFAULT_RATE_LIMIT_PER_MINUTE
    return {"rate_limit_per_minute": per_minute}


class RateLimiter:
    """Fixed-window per-client-IP request throttle (Phase 4 polish).

    Bounds request volume from any single IP — a supplement to token auth +
    failed-attempt lockout, never a replacement. Single-process, in-memory:
    each server process (and each create_app in tests) owns its counters.
    ``now`` is injectable so unit tests can skip the window without sleeping.
    """

    def __init__(
        self,
        per_minute: int = DEFAULT_RATE_LIMIT_PER_MINUTE,
        now: Callable[[], float] | None = None,
    ) -> None:
        self.per_minute = per_minute if per_minute >= 1 else DEFAULT_RATE_LIMIT_PER_MINUTE
        self._now = now or time.monotonic
        self._hits: dict[str, tuple[float, int]] = {}

    def allow(self, key: str) -> tuple[bool, float]:
        """Return (allowed, retry_after_seconds). Denials name the wait."""
        now = self._now()
        window_start, count = self._hits.get(key, (now, 0))
        if now - window_start >= 60.0:
            window_start, count = now, 0
        if count < self.per_minute:
            self._hits[key] = (window_start, count + 1)
            return True, 0.0
        return False, max(0.0, 60.0 - (now - window_start))


class RateLimitMiddleware:
    """Pure-ASGI per-IP throttle (Phase 4, review item 3).

    Deliberately NOT a BaseHTTPMiddleware: that wrapper buffers the request
    body and interposes on ``receive``, which breaks disconnect detection for
    long-lived streams (the /events follow-loop parks after one pass; MJPEG
    already had to route around it). This middleware never touches the body
    or ``receive`` — it counts ``scope["client"]`` and delegates untouched.
    """

    def __init__(self, app, limiter: RateLimiter) -> None:
        self.app = app
        self.limiter = limiter

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        client = scope.get("client")
        key = client[0] if client else "unknown"
        allowed, retry_after = self.limiter.allow(key)
        if not allowed:
            resp = JSONResponse(
                status_code=429,
                content=ERROR_RATE_LIMITED,
                headers={"Retry-After": str(int(retry_after) + 1)},
            )
            await resp(scope, receive, send)
            return
        await self.app(scope, receive, send)


async def _still_connected(request: Request, timeout: float = 0.5) -> bool:
    """Disconnect check that never parks a follow-loop.

    ``request.is_disconnected()`` blocks until the transport speaks, and with
    uvicorn there is exactly one pre-disconnect message — so a bare call runs
    a follow-loop once and then parks until the client goes away (new events
    would never stream). A timeout turns "no news" into "still attached" —
    the same pattern as ``streams._client_gone``. A real disconnect surfaces
    on the next poll, at most ``timeout`` late.
    """
    try:
        return not await asyncio.wait_for(request.is_disconnected(), timeout=timeout)
    except (asyncio.TimeoutError, TimeoutError):
        return True


def _bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        return ""
    return authorization[len("Bearer "):].strip()


def iter_log_events(log_path: Path, from_offset: int = 0) -> Iterator[tuple[str, dict]]:
    """Yield (event_type, payload) for each JSON line. Pure helper — unit tested."""
    with log_path.open(encoding="utf-8") as fh:
        fh.seek(from_offset)
        for line in fh:
            parsed = _parse_log_line(line)
            if parsed is not None:
                yield parsed


def _parse_log_line(line: str) -> tuple[str, dict] | None:
    """Parse one JSONL event line. Junk lines yield None (never raise)."""
    line = line.strip()
    if not line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    event_type = record.pop("type", "message")
    record.pop("at", None)
    return event_type, record


# v0.1.0 reconnect bound (human decision 4): a phone reconnecting after a
# day offline must NOT get the whole events.jsonl dumped on it in one shot
# (phone bandwidth/battery + one unbounded laptop-side read). Replay is
# capped to the trailing slice; "everything, paginated" is a v1.1 feature.
EVENTS_REPLAY_LIMIT = 200


def tail_log_events(log_path: Path, limit: int = EVENTS_REPLAY_LIMIT) -> list[tuple[str, dict]]:
    """Return the last `limit` events, oldest-first. Memory stays O(limit)."""
    if limit < 1:
        limit = EVENTS_REPLAY_LIMIT
    from collections import deque

    entries: deque[tuple[str, dict]] = deque(maxlen=limit)
    if not log_path.exists():
        return []
    with log_path.open(encoding="utf-8") as fh:
        for line in fh:
            parsed = _parse_log_line(line)
            if parsed is not None:
                entries.append(parsed)
    return list(entries)


def touch_activity(state: AuthState) -> None:
    """Stamp activity from ANY authenticated surface — commands, consent
    calls, and long-lived streams (/events keep-alives, /screen frames).

    Human decision (2): "idle" means no activity across the LAN surface,
    not "no /command issued" — a phone passively watching a live stream
    for an hour must not get bricked mid-session. AuthState.verify() stamps
    the same clock on discrete requests; the stream loops below call this
    explicitly because a single long-lived request stamps only once.
    """
    state.last_activity = state.now()


def format_sse(event_type: str, payload: dict) -> str:
    return f"event: {event_type}\ndata: {json.dumps(payload)}\n\n"


class _http_error(Exception):
    def __init__(self, status_code: int, content: dict):
        self.status_code = status_code
        self.content = content


def create_app(
    security_path: str | Path = SECURITY_PATH,
    event_log: str | Path | None = None,
) -> FastAPI:
    settings = load_auth_settings(security_path)
    prox_cfg = load_proximity_config(security_path)
    log_path = Path(event_log) if event_log else CONFIG_DIR.parent / "logs" / "events.jsonl"
    # The expiry notice sink follows the same JSONL the SSE /events endpoint
    # tails (auth.py DEFAULT_EVENT_LOG when None). create_app's event_log lets
    # tests redirect BOTH the tail and the auth emit to a tmp file — otherwise
    # a lone expired-token test writes into the production events.jsonl.
    state = AuthState(settings=settings, event_log=log_path)

    # SECURITY.md: no unauthenticated endpoint except /health. FastAPI's
    # interactive docs + openapi.json would otherwise expose the full route
    # map (including /screen consent paths) without a token — disable them.
    app = FastAPI(title="Everyday Buddy control server", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.auth_state = state
    consent = streams.ConsentManager()
    app.state.consent_manager = consent

    # Per-IP request throttle from config/security.yaml (review item 3).
    # Runs before auth so one noisy client can't starve the loop; 429s carry
    # the API.md error envelope plus a Retry-After hint. /health is throttled
    # too — unauthenticated probing gets no free pass.
    limiter = RateLimiter(per_minute=load_network_config(security_path)["rate_limit_per_minute"])
    app.state.rate_limiter = limiter
    app.add_middleware(RateLimitMiddleware, limiter=limiter)

    @app.exception_handler(_http_error)
    async def handle_http_error(_: Request, exc: _http_error) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.content)

    def require_auth(request: Request) -> AuthState:
        token = _bearer_token(request.headers.get("authorization"))
        if state.is_locked():
            raise _http_error(429, ERROR_LOCKED)
        ok, code = state.verify_with_code(token)
        if ok:
            return state
        # Both 401s: the ceiling gets its own code so the expiring device
        # learns to re-pair from THIS response — it must not depend on ever
        # seeing the broadcast token_expired SSE frame (which needs auth).
        if code == "token_expired":
            raise _http_error(401, ERROR_TOKEN_EXPIRED)
        raise _http_error(401, ERROR_UNAUTHORIZED)

    def require_near(request: Request, auth: AuthState = Depends(require_auth)) -> AuthState:
        # HUMAN DECISION (1) — X-RSSI is self-attested and DECORATIVE. Its
        # ONLY server-side use is this near/far gate (fail-closed to far).
        # Auth identity, lockout, throttling, and consent must NEVER branch
        # on it — a client can send any value it likes. If you're tempted to
        # add "weak RSSI → also throttle" as a harmless optimization: don't.
        # That would promote a spoofable hint into a security input.
        rssi: float | None = None
        raw = request.headers.get("x-rssi")
        if raw is not None:
            try:
                rssi = float(raw)
            except ValueError:
                rssi = None
        if get_proximity(prox_cfg, rssi) != "near":
            raise _http_error(403, ERROR_FORBIDDEN)
        return auth

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    @app.get("/proximity")
    def proximity(_auth: AuthState = Depends(require_auth)) -> dict:
        """Authenticated proximity config for the phone indicator (Phase 4).

        Read-only and non-sensitive (mode + threshold only — never the token).
        Allowed in BOTH near and far: the indicator needs it most when far.
        The phone applies the threshold locally to its BLE RSSI; the X-RSSI
        it sends back stays decorative (human decision 1).
        """
        return {
            "mode": prox_cfg.get("mode", "lan_only"),
            "rssi_near_threshold": prox_cfg.get("rssi_near_threshold", -60),
        }

    @app.post("/command")
    def command(body: dict, background: BackgroundTasks, _auth: AuthState = Depends(require_near)) -> dict:
        from buddy_core import orchestrator

        text = str(body.get("text", "")).strip()
        if not text:
            raise _http_error(400, {"error": {"code": "bad_request", "message": "Missing 'text'"}})
        task_id = uuid.uuid4().hex[:12]
        # Quality-first: text/API callers prefer target_model (llama3.1:8b).
        # Voice-loop latency routing lives in voice/voice_loop.py (source="voice").
        background.add_task(orchestrator.run, text, task_id, "text")
        return {"task_id": task_id, "status": "queued"}

    @app.get("/events")
    def events(request: Request, _auth: AuthState = Depends(require_auth)):
        async def stream():
            offset = log_path.stat().st_size if log_path.exists() else 0
            # Bounded replay (decision 4) — trailing slice only, then follow.
            for event_type, payload in tail_log_events(log_path):
                yield format_sse(event_type, payload)
            # …then follow new lines until the client disconnects.
            while await _still_connected(request):
                await asyncio.sleep(0.5)
                if not log_path.exists():
                    continue
                size = log_path.stat().st_size
                if size < offset:
                    offset = 0  # rotated/truncated
                if size > offset:
                    for event_type, payload in iter_log_events(log_path, offset):
                        yield format_sse(event_type, payload)
                    offset = size
                touch_activity(state)  # keep-alives are activity (decision 2)

        return StreamingResponse(stream(), media_type="text/event-stream")

    @app.post("/screen/consent")
    def screen_consent(_auth: AuthState = Depends(require_near)) -> dict:
        """Create a PENDING screen-share consent request (near-only).

        v1: the request stays pending until approved from the laptop via
        POST /screen/consent/{id}/approve. A real OS-level prompt is a
        v1.1 upgrade.
        """
        consent_id = consent.start_consent_request()
        return {"consent_id": consent_id, "status": "pending"}

    @app.post("/screen/consent/{consent_id}/approve")
    def screen_consent_approve(consent_id: str, _auth: AuthState = Depends(require_near)) -> dict:
        """Laptop-side approval for a pending screen-share request (near-only)."""
        if consent.approve(consent_id):
            return {"consent_id": consent_id, "status": "approved"}
        status = consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        if status is streams.ConsentStatus.DENIED:
            raise _http_error(409, ERROR_CONSENT_DENIED)
        raise _http_error(400, {"error": {"code": "bad_request", "message": "Consent request is not pending"}})

    @app.post("/screen/consent/{consent_id}/deny")
    def screen_consent_deny(consent_id: str, _auth: AuthState = Depends(require_near)) -> dict:
        """Laptop-side denial for a pending screen-share request (near-only)."""
        if consent.deny(consent_id):
            return {"consent_id": consent_id, "status": "denied"}
        status = consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        raise _http_error(409, {"error": {"code": "conflict", "message": "Consent already approved"}})

    @app.post("/screen/consent/{consent_id}/revoke")
    def screen_consent_revoke(consent_id: str, _auth: AuthState = Depends(require_near)) -> dict:
        """Laptop-side early revocation of a live grant (near-only).

        Revocation takes effect on the next per-frame re-check, so a live
        /screen stream stops within ~1 frame interval.
        """
        if consent.revoke(consent_id):
            return {"consent_id": consent_id, "status": "revoked"}
        status = consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        raise _http_error(409, {"error": {"code": "conflict", "message": "Consent is not an active grant"}})

    @app.get("/screen")
    def screen(request: Request, _auth: AuthState = Depends(require_near)) -> StreamingResponse:
        """MJPEG stream of the primary display — near-only AND consent-gated.

        The client passes the approved grant as ``?consent_id=…`` or the
        ``X-Consent-Id`` header. Anything else fails closed with 403. The
        grant is re-checked on every frame, so expiry stops a live stream.
        """
        consent_id = request.query_params.get("consent_id") or request.headers.get("x-consent-id") or ""
        status = consent.status_of(consent_id)
        if status is None:
            raise _http_error(403, ERROR_CONSENT_REQUIRED)
        if status in (streams.ConsentStatus.DENIED, streams.ConsentStatus.REVOKED):
            raise _http_error(403, ERROR_CONSENT_DENIED)
        if status is not streams.ConsentStatus.APPROVED:
            raise _http_error(403, ERROR_CONSENT_REQUIRED)

        def build_gen():
            for chunk in streams.mjpeg_generator(consent_valid=lambda: consent.is_approved(consent_id)):
                touch_activity(state)  # frame pulls are activity (decision 2)
                yield chunk

        return streams.MJPEGResponse(build_gen)

    return app


def build_app() -> FastAPI:
    return create_app()


app = create_app()
