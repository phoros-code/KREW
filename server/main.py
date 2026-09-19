"""FastAPI control server — endpoints exactly per API.md.

- GET  /health   — unauthenticated, minimal ({status: ok} only)
- POST /command  — near only, queues orchestrator.run() in the background
- GET  /events   — near or far, SSE tail of logs/events.jsonl
- GET  /screen   — near only, 501 until the Phase 3 MJPEG implementation

Every route except /health requires the bearer dependency from server.auth.
Proximity failures default to FAR (fail closed — SECURITY.md).
"""

from __future__ import annotations

import asyncio
import json
import uuid
from pathlib import Path
from typing import Iterator

import yaml
from fastapi import BackgroundTasks, Depends, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from buddy_core.config import CONFIG_DIR
from server.auth import SECURITY_PATH, AuthState, load_auth_settings

ERROR_UNAUTHORIZED = {"error": {"code": "unauthorized", "message": "Invalid or expired token"}}
ERROR_FORBIDDEN = {"error": {"code": "forbidden", "message": "Requires near proximity"}}
ERROR_LOCKED = {"error": {"code": "locked_out", "message": "Too many failed attempts — try again later"}}


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


def _bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        return ""
    return authorization[len("Bearer "):].strip()


def iter_log_events(log_path: Path, from_offset: int = 0) -> Iterator[tuple[str, dict]]:
    """Yield (event_type, payload) for each JSON line. Pure helper — unit tested."""
    with log_path.open(encoding="utf-8") as fh:
        fh.seek(from_offset)
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            event_type = record.pop("type", "message")
            record.pop("at", None)
            yield event_type, record


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
    state = AuthState(settings=settings)
    prox_cfg = load_proximity_config(security_path)
    log_path = Path(event_log) if event_log else CONFIG_DIR.parent / "logs" / "events.jsonl"

    app = FastAPI(title="Everyday Buddy control server")
    app.state.auth_state = state

    @app.exception_handler(_http_error)
    async def handle_http_error(_: Request, exc: _http_error) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.content)

    def require_auth(request: Request) -> AuthState:
        token = _bearer_token(request.headers.get("authorization"))
        if state.is_locked():
            raise _http_error(429, ERROR_LOCKED)
        if not state.verify(token):
            raise _http_error(401, ERROR_UNAUTHORIZED)
        return state

    def require_near(request: Request, auth: AuthState = Depends(require_auth)) -> AuthState:
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

    @app.post("/command")
    def command(body: dict, background: BackgroundTasks, _auth: AuthState = Depends(require_near)) -> dict:
        from buddy_core import orchestrator

        text = str(body.get("text", "")).strip()
        if not text:
            raise _http_error(400, {"error": {"code": "bad_request", "message": "Missing 'text'"}})
        task_id = uuid.uuid4().hex[:12]
        background.add_task(orchestrator.run, text, task_id)
        return {"task_id": task_id, "status": "queued"}

    @app.get("/events")
    def events(request: Request, _auth: AuthState = Depends(require_auth)):
        async def stream():
            offset = log_path.stat().st_size if log_path.exists() else 0
            # Replay what exists now…
            for event_type, payload in iter_log_events(log_path, 0):
                yield format_sse(event_type, payload)
            # …then follow new lines until the client disconnects.
            while True:
                if await request.is_disconnected():
                    break
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

        return StreamingResponse(stream(), media_type="text/event-stream")

    @app.get("/screen")
    def screen(_auth: AuthState = Depends(require_near)) -> JSONResponse:
        # MJPEG preview lands in Phase 3 with the consent gate (SECURITY.md).
        return JSONResponse(
            status_code=501,
            content={"error": {"code": "not_implemented", "message": "Screen preview ships in Phase 3"}},
        )

    return app


def build_app() -> FastAPI:
    return create_app()


app = create_app()
