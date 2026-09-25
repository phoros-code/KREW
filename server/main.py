"""FastAPI control server — endpoints exactly per API.md.

- GET  /health   — unauthenticated, minimal ({status: ok} only)
- POST /command  — near only, queues orchestrator.run() in the background
- GET  /events   — near or far, SSE tail of logs/events.jsonl
- GET  /screen   — near only + explicit consent grant, MJPEG stream
- POST /screen/consent (+ /{id}/approve, /{id}/deny, /{id}/revoke) — consent flow, near only
- GET  /webcam   — near only + explicit consent grant (separate scope from /screen), MJPEG webcam stream
- POST /webcam/consent (+ /{id}/approve, /{id}/deny, /{id}/revoke) — consent flow, near only

Every route except /health requires the bearer dependency from server.auth.
Proximity failures default to FAR (fail closed — SECURITY.md).
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Callable, Iterator

import yaml
from fastapi import BackgroundTasks, Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response as _StarletteResponse
from starlette.types import Receive, Scope, Send

from buddy_core.config import CONFIG_DIR
from server import streams
from server.auth import (
    SECURITY_PATH,
    _SECURITY_WRITE_LOCK,
    _atomic_write_yaml,
    AuthState,
    load_auth_settings,
)

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
# Webcam consent envelopes: same codes/shapes as the screen ones above so the
# phone app handles them uniformly — only the human-readable message differs.
# A screen approval must NEVER authorize /webcam and vice versa (separate
# ConsentManager scope below).
ERROR_WEBCAM_CONSENT_REQUIRED = {
    "error": {"code": "consent_required", "message": "Webcam access requires explicit on-device consent"}
}
ERROR_WEBCAM_CONSENT_DENIED = {
    "error": {"code": "consent_denied", "message": "Webcam access request was denied"}
}
ERROR_CONSENT_NOT_FOUND = {"error": {"code": "not_found", "message": "Unknown consent request"}}
ERROR_APPROVAL_FORBIDDEN = {
    "error": {
        "code": "approval_forbidden",
        "message": "Consent approval requires laptop confirmation (loopback or approval secret)",
    }
}
ERROR_STREAM_LIMIT = {
    "error": {"code": "stream_limit", "message": "Too many concurrent streams — retry shortly"}
}
ERROR_RATE_LIMITED = {
    "error": {"code": "rate_limited", "message": "Too many requests — slow down and try again shortly"}
}
ERROR_IDLE_EXPIRED = {
    "error": {"code": "idle_expired", "message": "Session idle — re-authenticate from the laptop"}
}
ERROR_BUSY = {
    "error": {"code": "busy", "message": "Server busy — too many commands in flight"}
}
# Stream-termination variant of the absolute-ceiling envelope: same code/shape
# as ERROR_TOKEN_EXPIRED so phone handling is uniform — emitted as the final
# SSE `event: error` frame when a live stream outlives the 30-day ceiling.
ERROR_TOKEN_EXPIRED_STREAM = {
    "error": {"code": "token_expired", "message": "Pairing token exceeded its absolute age — re-pair from the laptop"}
}

# Documented default for network.rate_limit_per_minute (CONFIG.md).
# Missing/unparseable config falls back here — never to "unlimited".
DEFAULT_RATE_LIMIT_PER_MINUTE = 60

# /command input bound (Track A1): kills oversized payloads before they reach
# the orchestrator. Module constant near the route per spec.
MAX_COMMAND_CHARS = 2000
# Bounded in-flight /command work (Track A1): at most N BackgroundTask bodies
# run concurrently; the N+1th request gets 503 busy (non-blocking acquire).
MAX_COMMAND_INFLIGHT = 4


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


def load_streams_follow_flag(path: str | Path = SECURITY_PATH) -> bool:
    """Read `streams_follow_counts_as_activity` (Track A1).

    Default False: stream keep-alive ticks do NOT extend idle — idle decays
    from real requests only (SECURITY.md). When True, keeps the pre-A1
    behaviour (each tick stamps activity). Accepts a top-level key or an
    `auth:`-nested key (both read, top-level wins) for forwards compat.
    """
    path = Path(path)
    src = path if path.exists() else CONFIG_DIR / "security.yaml.example"
    if not src.exists():
        return False
    try:
        data = yaml.safe_load(src.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return False
    if not isinstance(data, dict):
        return False
    if "streams_follow_counts_as_activity" in data:
        return bool(data.get("streams_follow_counts_as_activity"))
    auth = data.get("auth")
    if isinstance(auth, dict) and "streams_follow_counts_as_activity" in auth:
        return bool(auth.get("streams_follow_counts_as_activity"))
    return False


def load_streams_config(path: str | Path = SECURITY_PATH) -> dict:
    """Read the `streams:` block (Track A3) with module constants as defaults.

    Single entry point for routes/tests: delegates to
    streams.load_streams_config so both import paths agree. Missing file,
    missing block, or garbage values fall back to TARGET_FPS (2.0),
    MAX_CONSECUTIVE_FAILURES (10), PENDING_TTL (300s), GRANT_TTL (900s),
    MAX_CONSENT_RECORDS (256) — never unlimited/zero.
    """
    try:
        p = Path(path)
        src: str | Path = p if p.exists() else (CONFIG_DIR / "security.yaml.example")
        return streams.load_streams_config(src)
    except Exception:
        return streams.load_streams_config(None)


def _is_loopback(host: str | None) -> bool:
    """True only for 127.0.0.1 / ::1 (Track A3 laptop-only approval)."""
    if not host:
        return False
    text = str(host).strip().strip("[]").lower()
    return text in ("127.0.0.1", "::1")


def _client_ip(request: Request) -> str:
    """Extract the client IP for per-IP lockout buckets. Never empty."""
    try:
        client = request.client
        if client is not None:
            host = getattr(client, "host", None) or (client[0] if isinstance(client, (tuple, list)) else None)
            if host:
                return str(host)
    except Exception:
        pass
    # Pure-ASGI scope fallback (direct-ASGI tests build scope dicts).
    try:
        scope = getattr(request, "scope", None)
        if isinstance(scope, dict):
            client = scope.get("client")
            if client and client[0]:
                return str(client[0])
    except Exception:
        pass
    return "unknown"


def _envelope_for_code(code: str) -> dict:
    """Map a verify_with_code failure code to its {error:{code,message}} envelope."""
    if code == "token_expired":
        return ERROR_TOKEN_EXPIRED_STREAM
    if code == "idle_expired":
        return ERROR_IDLE_EXPIRED
    if code == "locked_out":
        return ERROR_LOCKED
    return ERROR_UNAUTHORIZED


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
        # Evict stale windows so _hits stays bounded (Track A1): any entry
        # whose window started >=60s ago is dead and must not accumulate.
        for other, (ws, _c) in list(self._hits.items()):
            if now - ws >= 60.0:
                del self._hits[other]
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
    """Return the last `limit` events, oldest-first. Memory stays O(limit).

    Track A2 — bounded tail: seeks from the END in 8KB blocks instead of
    scanning the whole file, so a 5MB log (or a 10k-line test log) replays
    in milliseconds. Junk lines are skipped via _parse_log_line; when junk
    is dense we keep reading backwards until `limit` valid events or BOF.
    """
    if limit < 1:
        limit = EVENTS_REPLAY_LIMIT
    from collections import deque

    if not log_path.exists():
        return []
    try:
        with log_path.open("rb") as fh:
            fh.seek(0, 2)
            file_size = fh.tell()
            if file_size == 0:
                return []
            chunk_size = 8192
            buf = b""
            pos = file_size
            # Read backwards until we hold enough valid events or hit BOF.
            while True:
                read_size = min(chunk_size, pos)
                pos -= read_size
                fh.seek(pos)
                chunk = fh.read(read_size)
                buf = chunk + buf
                text = buf.decode("utf-8", errors="replace")
                lines = text.splitlines()
                # When pos > 0 the first line is a partial head — exclude it
                # until we have read the start of the file.
                candidate = lines if pos == 0 else (lines[1:] if lines else [])
                valid = 0
                for ln in candidate:
                    if _parse_log_line(ln) is not None:
                        valid += 1
                        if valid >= limit:
                            break
                if valid >= limit or pos == 0:
                    entries: deque[tuple[str, dict]] = deque(maxlen=limit)
                    for ln in candidate:
                        parsed = _parse_log_line(ln)
                        if parsed is not None:
                            entries.append(parsed)
                    return list(entries)
                # Not enough valid yet — keep reading backwards. Cap the
                # in-memory tail at ~1MB to stay bounded even for all-junk
                # files; beyond that parse what we hold (still correct,
                # just fewer than `limit`).
                if len(buf) > 1024 * 1024:
                    entries = deque(maxlen=limit)
                    for ln in candidate:
                        parsed = _parse_log_line(ln)
                        if parsed is not None:
                            entries.append(parsed)
                    # If we already hold `limit` we would have returned;
                    # otherwise keep going only if the file is not absurdly
                    # large — for the 5MB production cap two more 8KB reads
                    # are cheap, so just continue.
                    pass
    except OSError:
        return []
    return []


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


# Track A2 — sync file-I/O shims so the /events async generator never
# blocks the loop; every call site below runs them via asyncio.to_thread.
def _sync_stat_size(path: Path) -> int:
    try:
        return path.stat().st_size if path.exists() else 0
    except OSError:
        return 0


def _sync_tail(path: Path) -> list[tuple[str, dict]]:
    try:
        return tail_log_events(path)
    except OSError:
        return []


def _sync_read_from(path: Path, offset: int) -> list[tuple[str, dict]]:
    try:
        return list(iter_log_events(path, offset))
    except OSError:
        return []


async def _events_client_gone(receive: Receive, timeout: float = 0.5) -> bool:
    """Non-blocking disconnect poll for the SSE stream (Track A2).

    Own receive polling on the MJPEGResponse pattern — never calls
    ``request.is_disconnected()`` (which interposes on ``receive`` and
    double-consumes the single pre-disconnect message with uvicorn,
    parking the follow-loop). A stalled transport reads as connected.
    """
    try:
        message = await asyncio.wait_for(receive(), timeout=timeout)
    except (asyncio.TimeoutError, TimeoutError):
        return False
    except Exception:
        return True  # fail closed on transport errors
    return isinstance(message, dict) and message.get("type") == "http.disconnect"


# SSE keepalive + client retry (Track A2).
SSE_KEEPALIVE_SECONDS = 15.0
SSE_RETRY_MS = 3000


class SSEventsResponse(_StarletteResponse):
    """SSE /events response with own disconnect polling (Track A2).

    Ports the MJPEGResponse ASGI pattern: subclasses Starlette's Response
    so FastAPI serves it directly, but implements its own ``__call__``
    that never blocks unconditionally on ``receive()``. Disconnect is
    polled with a short timeout (the 0.5s follow cadence doubles as the
    poll), so the stream works on real servers (uvicorn delivers
    disconnect promptly) AND under in-process test transports.

    Wire shape:
    - ``cache-control: no-cache`` + ``X-Accel-Buffering: no`` (no proxy
      buffering — proxies must not hold SSE frames).
    - ``retry: 3000`` opener so a dropped phone reconnects after 3s.
    - ``: ping`` comment keepalive every 15s of silence (SSE comments are
      ignored by EventSource clients; they just reset proxy timeouts).
    """

    media_type = "text/event-stream"

    def __init__(
        self,
        log_path: Path,
        auth_state: AuthState,
        stream_token: str,
        stream_ip: str,
        follow_counts: bool,
    ) -> None:
        super().__init__(content=None, status_code=200, media_type=self.media_type)
        self.log_path = log_path
        self.auth_state = auth_state
        self.stream_token = stream_token
        self.stream_ip = stream_ip
        self.follow_counts = follow_counts

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if not isinstance(scope, dict) or scope.get("type") != "http":
            raise RuntimeError("SSEventsResponse requires an HTTP scope")
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [
                    (b"content-type", b"text/event-stream"),
                    (b"cache-control", b"no-cache"),
                    (b"x-accel-buffering", b"no"),
                ],
            }
        )
        state = self.auth_state
        log_path = self.log_path
        # Opener: client reconnection delay (SSE `retry` field).
        await send(
            {
                "type": "http.response.body",
                "body": f"retry: {SSE_RETRY_MS}\n\n".encode("ascii"),
                "more_body": True,
            }
        )
        last_send = time.monotonic()
        # Bounded replay (decision 4) — trailing slice only, then follow.
        # File I/O via to_thread so the loop never blocks (Track A2).
        offset = await asyncio.to_thread(_sync_stat_size, log_path)
        for event_type, payload in await asyncio.to_thread(_sync_tail, log_path):
            if await _events_client_gone(receive, timeout=0.01):
                await send({"type": "http.response.body", "body": b"", "more_body": False})
                return
            await send(
                {
                    "type": "http.response.body",
                    "body": format_sse(event_type, payload).encode("utf-8"),
                    "more_body": True,
                }
            )
            last_send = time.monotonic()
        # …then follow new lines until the client disconnects.
        while True:
            # Combined sleep + disconnect poll: 0.5s cadence, no
            # double-consume with is_disconnected.
            if await _events_client_gone(receive, timeout=0.5):
                break
            prev_activity = state.last_activity
            ok, code = state.verify_with_code(self.stream_token, self.stream_ip)
            if not self.follow_counts:
                state.last_activity = prev_activity
            if not ok:
                env = _envelope_for_code(code)
                await send(
                    {
                        "type": "http.response.body",
                        "body": format_sse("error", env).encode("utf-8"),
                        "more_body": True,
                    }
                )
                break
            size = await asyncio.to_thread(_sync_stat_size, log_path)
            exists = size > 0 or log_path.exists()
            if not exists:
                if self.follow_counts:
                    touch_activity(state)
                # Still account for keepalive during log-absent silence.
            else:
                if size < offset:
                    offset = 0  # rotated/truncated
                if size > offset:
                    for event_type, payload in await asyncio.to_thread(
                        _sync_read_from, log_path, offset
                    ):
                        await send(
                            {
                                "type": "http.response.body",
                                "body": format_sse(event_type, payload).encode("utf-8"),
                                "more_body": True,
                            }
                        )
                    offset = size
                    last_send = time.monotonic()
                if self.follow_counts:
                    touch_activity(state)
            # Keepalive comment on silence (ignored by SSE clients).
            now = time.monotonic()
            if now - last_send >= SSE_KEEPALIVE_SECONDS:
                await send(
                    {
                        "type": "http.response.body",
                        "body": b": ping\n\n",
                        "more_body": True,
                    }
                )
                last_send = now
        await send({"type": "http.response.body", "body": b"", "more_body": False})


class _http_error(Exception):
    def __init__(self, status_code: int, content: dict, headers: dict | None = None):
        self.status_code = status_code
        self.content = content
        self.headers = headers or {}


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
    # Track A3: streams config (streams: block) with module defaults.
    streams_cfg = load_streams_config(security_path)
    app.state.streams_config = streams_cfg
    consent = streams.ConsentManager(
        pending_ttl=float(streams_cfg.get("pending_ttl_seconds", streams.PENDING_TTL_SECONDS)),
        grant_ttl=float(streams_cfg.get("grant_ttl_seconds", streams.GRANT_TTL_SECONDS)),
        max_records=int(streams_cfg.get("max_consent_records", streams.MAX_CONSENT_RECORDS)),
        target_fps=float(streams_cfg.get("target_fps", streams.TARGET_FPS)),
        max_consecutive_failures=int(
            streams_cfg.get("max_consecutive_failures", streams.MAX_CONSECUTIVE_FAILURES)
        ),
    )
    app.state.consent_manager = consent
    # Separate consent scope for the webcam: a screen approval must NEVER
    # authorize /webcam and vice versa. Same TTLs/bounds (streams: block) —
    # distinct record store + distinct live-stream counters.
    webcam_consent = streams.ConsentManager(
        pending_ttl=float(streams_cfg.get("pending_ttl_seconds", streams.PENDING_TTL_SECONDS)),
        grant_ttl=float(streams_cfg.get("grant_ttl_seconds", streams.GRANT_TTL_SECONDS)),
        max_records=int(streams_cfg.get("max_consent_records", streams.MAX_CONSENT_RECORDS)),
        target_fps=float(streams_cfg.get("target_fps", streams.TARGET_FPS)),
        max_consecutive_failures=int(
            streams_cfg.get("max_consecutive_failures", streams.MAX_CONSECUTIVE_FAILURES)
        ),
    )
    app.state.webcam_consent = webcam_consent

    # Per-IP request throttle from config/security.yaml (review item 3).
    # Runs before auth so one noisy client can't starve the loop; 429s carry
    # the API.md error envelope plus a Retry-After hint. /health is throttled
    # too — unauthenticated probing gets no free pass.
    limiter = RateLimiter(per_minute=load_network_config(security_path)["rate_limit_per_minute"])
    app.state.rate_limiter = limiter
    app.add_middleware(RateLimitMiddleware, limiter=limiter)

    # Track A1: whether stream keep-alive ticks count as activity. Default
    # False — idle decays from real requests only (SECURITY.md). When True,
    # keeps the pre-A1 heartbeat behaviour.
    streams_follow_counts_as_activity = load_streams_follow_flag(security_path)
    app.state.streams_follow_counts_as_activity = streams_follow_counts_as_activity

    # Track A1: bounded in-flight /command work. Per-app (not module-global)
    # so tests get a fresh budget per create_app and can't pollute each other.
    command_sem = threading.Semaphore(MAX_COMMAND_INFLIGHT)
    app.state.command_semaphore = command_sem

    @app.exception_handler(_http_error)
    async def handle_http_error(_: Request, exc: _http_error) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.content, headers=exc.headers)

    # Track A2 — uniform envelope: every error, including framework-raised
    # validation/404/405, uses {error:{code,message}}. Existing codes/shapes
    # are untouched; these handlers only cover paths that previously
    # returned FastAPI's {"detail": [...]} array.
    # Auth-first preserved: these handlers run AFTER auth dependencies, so
    # an unauthenticated malformed request still 401s via require_auth
    # (envelope), while an authenticated malformed body 422s here
    # (envelope) — no path returns a bare detail array.
    @app.exception_handler(RequestValidationError)
    async def handle_validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={"error": {"code": "validation_error", "message": "Request validation failed"}},
        )

    @app.exception_handler(StarletteHTTPException)
    async def handle_starlette_http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        if exc.status_code == 404:
            return JSONResponse(
                status_code=404,
                content={"error": {"code": "not_found", "message": "Not found"}},
            )
        if exc.status_code == 405:
            return JSONResponse(
                status_code=405,
                content={"error": {"code": "method_not_allowed", "message": "Method not allowed"}},
            )
        detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": {"code": "http_error", "message": detail}},
        )

    def require_auth(request: Request) -> AuthState:
        token = _bearer_token(request.headers.get("authorization"))
        ip = _client_ip(request)
        if state.is_locked(ip):
            raise _http_error(429, ERROR_LOCKED)
        ok, code = state.verify_with_code(token, ip)
        if ok:
            return state
        # Both 401s: the ceiling gets its own code so the expiring device
        # learns to re-pair from THIS response — it must not depend on ever
        # seeing the broadcast token_expired SSE frame (which needs auth).
        if code == "token_expired":
            raise _http_error(401, ERROR_TOKEN_EXPIRED)
        if code == "locked_out":
            raise _http_error(429, ERROR_LOCKED)
        if code == "idle_expired":
            raise _http_error(401, ERROR_IDLE_EXPIRED)
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

    def require_approval(request: Request, auth: AuthState = Depends(require_near)) -> AuthState:
        """Laptop-only gate for consent approve/deny (Track A3, BREAKING).

        Passes when EITHER:
        - the TCP peer is loopback (127.0.0.1 / ::1 — approval tapped on
          the laptop itself, e.g. curl from the laptop), OR
        - header X-Buddy-Approval constant-time-matches
          auth.consent_approval_secret (hmac.compare_digest).

        Revoke is NOT gated here (fail-closed stop must always work from
        the phone). Consent-request creation is NOT gated here (phone +
        near only).

        The secret is always present: fresh installs generate one on first
        run, and legacy files get one backfilled on load (see
        auth.load_auth_settings). There is no "no secret" mode — an empty
        secret fails closed with 403 approval_forbidden for everyone except
        loopback.
        """
        secret = (settings.consent_approval_secret or "").strip()
        if not secret:
            return auth  # legacy/test path: no secret configured
        if _is_loopback(_client_ip(request)):
            return auth
        provided = request.headers.get("x-buddy-approval", "")
        # compare_digest needs same types; both str (ascii hex). A wrong
        # length just returns False (no exception) for str inputs.
        try:
            if provided and hmac.compare_digest(provided.strip(), secret):
                return auth
        except Exception:
            pass
        raise _http_error(403, ERROR_APPROVAL_FORBIDDEN)

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

    @app.post("/proximity/threshold")
    def proximity_threshold(body: dict, _auth: AuthState = Depends(require_near)) -> dict:
        """Update the BLE RSSI near threshold (near-only, Sprint 2.3).

        The value is UX-only downstream: the phone fetches it via
        GET /proximity and applies it locally to its BLE readings (the
        X-RSSI it sends back stays decorative — human decision 1). The
        endpoint still requires full auth (token + near) because an
        unauthenticated config-write is a DoS/annoyance vector.

        Validation is strict and fails closed with 400 ``bad_request``:
        the value must be of JSON/int type (``type(value) is int`` —
        floats, numeric strings, and bools are REJECTED even when they
        would coerce losslessly, to avoid ambiguity about what the phone
        actually measured) and satisfy -100 <= value <= -30 (sane BLE
        dBm bounds; anything outside is nonsense, not a threshold).

        Persists to the SAME security.yaml file this app was created
        with (``security_path``), updating ONLY
        ``proximity.rssi_near_threshold`` and preserving all other keys
        (comments are lost — yaml.safe_load/safe_dump round-trip — keys
        are not), via atomic write (tmp file + rename). The in-memory
        ``prox_cfg`` is mutated too, so GET /proximity in this process
        reflects the new value without a restart.
        """
        value = body.get("rssi_near_threshold") if isinstance(body, dict) else None
        # Strict int: bool is a subclass of int, so `isinstance(True, int)`
        # is True — `type(value) is int` rejects True/False explicitly.
        if type(value) is not int:
            raise _http_error(
                400,
                {
                    "error": {
                        "code": "bad_request",
                        "message": "rssi_near_threshold must be an integer dBm value (strict int, -100..-30)",
                    }
                },
            )
        if not -100 <= value <= -30:
            raise _http_error(
                400,
                {
                    "error": {
                        "code": "bad_request",
                        "message": "rssi_near_threshold out of range: must satisfy -100 <= value <= -30",
                    }
                },
            )
        sec_path = Path(security_path)
        # Shared write lock with _persist_auth_file + rotate(): the whole
        # read-modify-write holds it so concurrent threshold+persist can't
        # interleave into a torn file. Unique tmp via tempfile + fsync + 0600
        # + atomic replace (see auth._atomic_write_yaml).
        with _SECURITY_WRITE_LOCK:
            sec_path.parent.mkdir(parents=True, exist_ok=True)
            data: dict = {}
            if sec_path.exists():
                try:
                    loaded = yaml.safe_load(sec_path.read_text(encoding="utf-8")) or {}
                except yaml.YAMLError:
                    loaded = {}
                if isinstance(loaded, dict):
                    data = loaded
            prox = data.get("proximity")
            if not isinstance(prox, dict):
                prox = {}
                data["proximity"] = prox
            prox["rssi_near_threshold"] = value
            _atomic_write_yaml(sec_path, data)
        prox_cfg["rssi_near_threshold"] = value
        return {"mode": prox_cfg.get("mode", "lan_only"), "rssi_near_threshold": value}

    @app.post("/command")
    def command(
        body: dict, background: BackgroundTasks, request: Request, _auth: AuthState = Depends(require_near)
    ) -> dict:
        from buddy_core import orchestrator

        raw = body.get("text") if isinstance(body, dict) else None
        # Strict str: null/number/list must 400, never coerce via str()
        # (kills the old null->"None" coercion).
        if not isinstance(raw, str):
            raise _http_error(400, {"error": {"code": "bad_request", "message": "Missing 'text'"}})
        text = raw.strip()
        if not text:
            raise _http_error(400, {"error": {"code": "bad_request", "message": "Missing 'text'"}})
        if len(text) > MAX_COMMAND_CHARS:
            raise _http_error(
                400,
                {
                    "error": {
                        "code": "bad_request",
                        "message": f"'text' exceeds {MAX_COMMAND_CHARS} characters",
                    }
                },
            )
        # Bounded in-flight work: non-blocking acquire; N+1th gets 503 busy.
        if not command_sem.acquire(blocking=False):
            raise _http_error(503, ERROR_BUSY)
        task_id = uuid.uuid4().hex[:12]

        def _run_and_release(t: str = text, tid: str = task_id) -> None:
            try:
                # Quality-first: text/API callers prefer target_model (llama3.1:8b).
                # Voice-loop latency routing lives in voice/voice_loop.py (source="voice").
                orchestrator.run(t, tid, "text")
            finally:
                command_sem.release()

        background.add_task(_run_and_release)
        return {"task_id": task_id, "status": "queued"}

    @app.get("/events")
    def events(request: Request, _auth: AuthState = Depends(require_auth)):
        # Capture the bearer for per-tick re-verification: no stream may
        # outlive the 30-day ceiling (Track A1). verify_with_code stamps
        # idle on success, so when the flag is False we restore last_activity
        # to keep idle decaying from real requests only.
        # Track A2: served by SSEventsResponse (custom ASGI on the
        # MJPEGResponse pattern — own receive polling, no double-consume
        # with is_disconnected; file I/O via to_thread; retry + keepalive).
        stream_token = _bearer_token(request.headers.get("authorization"))
        stream_ip = _client_ip(request)
        follow_counts = streams_follow_counts_as_activity
        return SSEventsResponse(log_path, state, stream_token, stream_ip, follow_counts)

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
    def screen_consent_approve(consent_id: str, _auth: AuthState = Depends(require_approval)) -> dict:
        """Laptop-only approval for a pending screen-share request.

        Track A3 (BREAKING): requires require_approval — loopback origin
        (curl from the laptop) OR X-Buddy-Approval matching
        auth.consent_approval_secret. Phone-token-only → 403
        approval_forbidden. Revoke stays phone-gated (fail-closed stop).
        """
        if consent.approve(consent_id):
            return {"consent_id": consent_id, "status": "approved"}
        status = consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        if status is streams.ConsentStatus.DENIED:
            raise _http_error(409, ERROR_CONSENT_DENIED)
        raise _http_error(400, {"error": {"code": "bad_request", "message": "Consent request is not pending"}})

    @app.post("/screen/consent/{consent_id}/deny")
    def screen_consent_deny(consent_id: str, _auth: AuthState = Depends(require_approval)) -> dict:
        """Laptop-only denial for a pending screen-share request."""
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
    def screen(request: Request, _auth: AuthState = Depends(require_near)) -> _StarletteResponse:
        """MJPEG stream of the primary display — near-only AND consent-gated.

        The client passes the approved grant as ``?consent_id=…`` or the
        ``X-Consent-Id`` header. Anything else fails closed with 403. The
        grant is re-checked on every frame, so expiry stops a live stream.

        Track A3 caps: 1 concurrent stream per consent id + 4 per client
        IP (429 stream_limit + Retry-After). One mss.mss() handle per
        stream (opened once, closed on generator exit).
        """
        consent_id = request.query_params.get("consent_id") or request.headers.get("x-consent-id") or ""
        status = consent.status_of(consent_id)
        if status is None:
            raise _http_error(403, ERROR_CONSENT_REQUIRED)
        if status in (streams.ConsentStatus.DENIED, streams.ConsentStatus.REVOKED):
            raise _http_error(403, ERROR_CONSENT_DENIED)
        if status is not streams.ConsentStatus.APPROVED:
            raise _http_error(403, ERROR_CONSENT_REQUIRED)

        stream_token = _bearer_token(request.headers.get("authorization"))
        stream_ip = _client_ip(request)
        follow_counts = streams_follow_counts_as_activity
        cfg_fps = float(streams_cfg.get("target_fps", streams.TARGET_FPS))
        cfg_max_fails = int(
            streams_cfg.get("max_consecutive_failures", streams.MAX_CONSECUTIVE_FAILURES)
        )

        # Single-handle capture: shared mss handle with fallback to the
        # mockable per-frame path (keeps existing capture_screen_jpeg
        # monkeypatches green; prod uses the shared handle).
        def _screen_capture(handle=None) -> bytes:
            if handle is not None:
                try:
                    return streams.capture_screen_frame(handle)
                except Exception:
                    pass
            return streams.capture_screen_jpeg()

        if not consent.try_acquire_stream(consent_id, stream_ip):
            raise _http_error(429, ERROR_STREAM_LIMIT, headers={"Retry-After": "5"})

        def build_gen():
            try:
                for chunk in streams.mjpeg_generator(
                    capture_fn=_screen_capture,
                    target_fps=cfg_fps,
                    max_consecutive_failures=cfg_max_fails,
                    handle_factory=streams.screen_handle,
                    consent_valid=lambda: consent.is_approved(consent_id),
                ):
                    prev_activity = state.last_activity
                    ok, _code = state.verify_with_code(stream_token, stream_ip)
                    if not follow_counts:
                        state.last_activity = prev_activity
                    if not ok:
                        # MJPEG already sent 200 headers: typed error can't be
                        # re-statused mid-multipart, so ending the stream IS the
                        # signal (no frame outlives the ceiling). The /events
                        # sibling above yields the matching error envelope.
                        break
                    if follow_counts:
                        touch_activity(state)
                    yield chunk
            finally:
                consent.release_stream(consent_id, stream_ip)

        return streams.MJPEGResponse(build_gen)

    @app.post("/webcam/consent")
    def webcam_consent_request(_auth: AuthState = Depends(require_near)) -> dict:
        """Create a PENDING webcam-access consent request (near-only).

        Separate scope from /screen: this grant authorizes ONLY /webcam.
        Same TTLs/bounds as screen (ConsentManager defaults).
        """
        consent_id = webcam_consent.start_consent_request()
        return {"consent_id": consent_id, "status": "pending"}

    @app.post("/webcam/consent/{consent_id}/approve")
    def webcam_consent_approve(consent_id: str, _auth: AuthState = Depends(require_approval)) -> dict:
        """Laptop-only approval for a pending webcam-access request."""
        if webcam_consent.approve(consent_id):
            return {"consent_id": consent_id, "status": "approved"}
        status = webcam_consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        if status is streams.ConsentStatus.DENIED:
            raise _http_error(409, ERROR_WEBCAM_CONSENT_DENIED)
        raise _http_error(400, {"error": {"code": "bad_request", "message": "Consent request is not pending"}})

    @app.post("/webcam/consent/{consent_id}/deny")
    def webcam_consent_deny(consent_id: str, _auth: AuthState = Depends(require_approval)) -> dict:
        """Laptop-only denial for a pending webcam-access request."""
        if webcam_consent.deny(consent_id):
            return {"consent_id": consent_id, "status": "denied"}
        status = webcam_consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        raise _http_error(409, {"error": {"code": "conflict", "message": "Consent already approved"}})

    @app.post("/webcam/consent/{consent_id}/revoke")
    def webcam_consent_revoke(consent_id: str, _auth: AuthState = Depends(require_near)) -> dict:
        """Laptop-side early revocation of a live webcam grant (near-only).

        Revocation takes effect on the next per-frame re-check, so a live
        /webcam stream stops within ~1 frame interval.
        """
        if webcam_consent.revoke(consent_id):
            return {"consent_id": consent_id, "status": "revoked"}
        status = webcam_consent.status_of(consent_id)
        if status is None:
            raise _http_error(404, ERROR_CONSENT_NOT_FOUND)
        raise _http_error(409, {"error": {"code": "conflict", "message": "Consent is not an active grant"}})

    @app.get("/webcam")
    def webcam(request: Request, _auth: AuthState = Depends(require_near)) -> _StarletteResponse:
        """MJPEG stream of the laptop webcam — near-only AND consent-gated.

        Mirrors /screen exactly, with a SEPARATE consent scope: only a grant
        from POST /webcam/consent authorizes this stream — a /screen grant
        fails closed with 403 here. The client passes the approved grant as
        ``?consent_id=…`` or the ``X-Consent-Id`` header. The grant is
        re-checked on every frame, so expiry/revocation stops a live stream.

        Track A3 caps: 1 concurrent stream per consent id + 4 per client
        IP (429 stream_limit + Retry-After). One cv2.VideoCapture per
        stream (opened once, released on generator exit).
        """
        consent_id = request.query_params.get("consent_id") or request.headers.get("x-consent-id") or ""
        status = webcam_consent.status_of(consent_id)
        if status is None:
            raise _http_error(403, ERROR_WEBCAM_CONSENT_REQUIRED)
        if status in (streams.ConsentStatus.DENIED, streams.ConsentStatus.REVOKED):
            raise _http_error(403, ERROR_WEBCAM_CONSENT_DENIED)
        if status is not streams.ConsentStatus.APPROVED:
            raise _http_error(403, ERROR_WEBCAM_CONSENT_REQUIRED)

        stream_token = _bearer_token(request.headers.get("authorization"))
        stream_ip = _client_ip(request)
        follow_counts = streams_follow_counts_as_activity
        cfg_fps = float(streams_cfg.get("target_fps", streams.TARGET_FPS))
        cfg_max_fails = int(
            streams_cfg.get("max_consecutive_failures", streams.MAX_CONSECUTIVE_FAILURES)
        )

        def _webcam_capture(handle=None) -> bytes:
            if handle is not None:
                try:
                    return streams.capture_webcam_frame(handle)
                except Exception:
                    pass
            return streams.capture_webcam_jpeg()

        if not webcam_consent.try_acquire_stream(consent_id, stream_ip):
            raise _http_error(429, ERROR_STREAM_LIMIT, headers={"Retry-After": "5"})

        def build_gen():
            try:
                for chunk in streams.mjpeg_generator(
                    capture_fn=_webcam_capture,
                    target_fps=cfg_fps,
                    max_consecutive_failures=cfg_max_fails,
                    handle_factory=streams.webcam_handle,
                    consent_valid=lambda: webcam_consent.is_approved(consent_id),
                ):
                    prev_activity = state.last_activity
                    ok, _code = state.verify_with_code(stream_token, stream_ip)
                    if not follow_counts:
                        state.last_activity = prev_activity
                    if not ok:
                        break
                    if follow_counts:
                        touch_activity(state)
                    yield chunk
            finally:
                webcam_consent.release_stream(consent_id, stream_ip)

        return streams.MJPEGResponse(build_gen)

    return app


def build_app() -> FastAPI:
    return create_app()


app = create_app()
