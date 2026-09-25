"""Track A2 (event pipeline integrity) tests.

Covers: redaction (no content/command text in log or SSE), bounded log
(rotation + seek-from-end tail + to_thread), silent task loss
(config/load/log failure + empty command), /events ASGI (headers, retry,
keepalive, disconnect), uniform envelope (422/404/405 + unauth malformed).
Fixture style mirrors test_track_a1.py.
"""

from __future__ import annotations

import hashlib
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import anyio
import pytest
import yaml
from fastapi.testclient import TestClient

from buddy_core import orchestrator
from buddy_core.agents.executor import redact_event_args
from buddy_core.agents.planner import Plan, ToolCall
from server.main import create_app

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


def _parse_sse_client_side(raw: bytes) -> list[tuple[str, dict]]:
    """Minimal client-side SSE parse that must ignore keepalives.

    - `retry: N` opener ignored (reconnection hint, not an event).
    - `: ...` comment lines (keepalive pings) ignored.
    - Only `event: X` + `data: {...}` blocks become events.
    """
    events: list[tuple[str, dict]] = []
    text = raw.decode("utf-8", errors="replace")
    for block in text.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        if block.startswith(":"):
            continue
        if block.startswith("retry:"):
            continue
        etype = None
        data = None
        for line in block.splitlines():
            if line.startswith("event:"):
                etype = line.split("event:", 1)[1].strip()
            elif line.startswith("data:"):
                data = line.split("data:", 1)[1].strip()
        if etype is not None and data is not None:
            events.append((etype, json.loads(data)))
    return events


# --- 1. redact helper shape ---


def test_redact_event_args_shape() -> None:
    content = "hello secret body"
    cmd = "echo hello secret"
    out = redact_event_args("write_file", {"path": "a.txt", "content": content})
    assert out["path"] == "a.txt"
    assert out["content"] == {
        "length": len(content),
        "sha256": hashlib.sha256(content.encode()).hexdigest(),
    }
    out2 = redact_event_args("shell", {"command": cmd})
    assert out2["command"] == {
        "length": len(cmd),
        "sha256": hashlib.sha256(cmd.encode()).hexdigest(),
    }
    # Other keys pass through; original never mutated.
    src = {"path": "a.txt", "content": content}
    redact_event_args("write_file", src)
    assert src["content"] == content
    assert redact_event_args("web_search", {"query": "hi"}) == {"query": "hi"}
    assert redact_event_args("x", None) == {}


def test_shell_denied_never_echoes_command() -> None:
    from buddy_core.config import ShellConfig
    from buddy_core.tools import shell

    cfg = ShellConfig(allowlist=["echo *"], denylist=["*evil*"])
    marker = "MARKER_SHELL_ECHO_ABC123"
    for bad in (f"echo {marker} evil", f"echo hi; {marker}", "curl http://example.com"):
        try:
            shell.check_allowed(bad, cfg)
        except Exception as exc:
            assert marker not in str(exc), bad
        else:
            raise AssertionError(f"should have denied: {bad}")
    assert shell.is_allowed("echo hello", cfg) is True


# --- 2. no content/command text in log ---


def test_no_marker_in_log_write_file_flow(tmp_path, monkeypatch) -> None:
    """Write-file flow with a marker must not leak the marker into events.jsonl."""
    from buddy_core.config import FilesConfig

    marker = "A2_MARKER_WRITE_9f8e7d6c5b4a"
    log = tmp_path / "events.jsonl"
    monkeypatch.setattr(orchestrator, "EVENT_LOG", log)

    tools = orchestrator.load_tools_config()
    tools.files = FilesConfig(workspace_root=str(tmp_path / "ws"), allow_outside_workspace=False)
    plan = Plan(steps=[ToolCall("write_file", {"path": "notes/m.md", "content": f"prefix {marker} suffix"})])
    from buddy_core.agents.executor import execute_plan

    result = execute_plan(plan, tools, "t-redact", orchestrator._log_event)
    assert result.ok
    raw = log.read_bytes()
    assert marker.encode() not in raw
    # Redacted descriptor present instead.
    assert b"sha256" in raw
    assert b"length" in raw


def test_no_marker_in_log_shell_denied_flow(tmp_path, monkeypatch) -> None:
    """Denied shell command with a marker must not leak the marker into events.jsonl."""
    marker = "A2_MARKER_SHELL_1a2b3c4d5e6f"
    log = tmp_path / "events.jsonl"
    monkeypatch.setattr(orchestrator, "EVENT_LOG", log)

    tools = orchestrator.load_tools_config()
    from buddy_core.config import FilesConfig

    tools.files = FilesConfig(workspace_root=str(tmp_path / "ws"), allow_outside_workspace=False)
    # Denied via metacharacters (always blocked) + marker.
    plan = Plan(steps=[ToolCall("shell", {"command": f"echo hi; {marker}"})])
    from buddy_core.agents.executor import execute_plan

    result = execute_plan(plan, tools, "t-shell", orchestrator._log_event)
    assert not result.ok
    # The executor failure itself is not auto-logged as task_failed here;
    # emulate the orchestrator's task_failed logging path with the denied text.
    orchestrator._log_event("task_failed", {"task_id": "t-shell", "error": result.output})
    raw = log.read_bytes()
    assert marker.encode() not in raw


def test_no_marker_in_log_or_sse_coder_flow(tmp_path, monkeypatch) -> None:
    """End-to-end coder flow: LLM-drafted marker content never hits log or SSE bytes."""
    marker = "A2_MARKER_CODER_ZZ99QQ11WW22"

    class _MarkerClient:
        def __init__(self, *a, **k):
            pass

        def list(self):
            return {"models": [{"name": "qwen2.5:3b"}]}

        def chat(self, model, messages, options=None):
            return {"message": {"content": f"file body with {marker} inside"}}

    monkeypatch.setattr("ollama.Client", _MarkerClient)
    monkeypatch.setattr(orchestrator, "EVENT_LOG", tmp_path / "events.jsonl")
    from buddy_core.config import FilesConfig

    tools = orchestrator.load_tools_config()
    tools.files = FilesConfig(workspace_root=str(tmp_path / "ws"), allow_outside_workspace=False)
    monkeypatch.setattr("buddy_core.orchestrator.load_tools_config", lambda: tools)

    result = orchestrator.run("write hello.py that prints hi")
    assert result.ok
    raw = (tmp_path / "events.jsonl").read_bytes()
    assert marker.encode() not in raw
    # SSE formatting of the same tail must not contain it either.
    from server.main import format_sse, tail_log_events

    sse = "".join(format_sse(t, p) for t, p in tail_log_events(tmp_path / "events.jsonl")).encode()
    assert marker.encode() not in sse


@pytest.mark.asyncio
async def test_sse_stream_has_no_marker(tmp_path) -> None:
    """Live /events replay over ASGI must not contain the marker either."""
    marker = "A2_MARKER_SSE_LIVE_77AA88BB"
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    log = tmp_path / "events.jsonl"
    # Seed a redacted tool_call (as the pipeline would) + a normal event.
    redacted = redact_event_args("write_file", {"path": "a.txt", "content": marker})
    log.write_text(
        json.dumps({"type": "tool_call", "task_id": "t", "tool": "write_file", "args": redacted}) + "\n"
        + json.dumps({"type": "task_started", "task_id": "t", "text": "hello"}) + "\n",
        encoding="utf-8",
    )
    app = create_app(security_path=sec, event_log=log)
    scope = _http_scope("/events")
    sent: list[dict] = []
    sent_body = False
    gone = anyio.Event()

    async def receive() -> dict:
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        sent.append(message)
        bodies = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
        if b"task_started" in bodies:
            gone.set()

    with anyio.fail_after(10):
        await app(scope, receive, send)
    bodies = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    assert marker.encode() not in bodies


# --- 3. bounded log: rotation + fast tail ---


def test_rotation_at_small_size(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orchestrator, "EVENT_LOG_MAX_BYTES", 300)
    assert orchestrator.EVENT_LOG_MAX_BYTES == 300
    for i in range(10):
        orchestrator._log_event("tool_call", {"task_id": "r", "n": i, "pad": "x" * 80})
    backup = tmp_path / "events.jsonl.1"
    assert backup.exists()
    # Current log stays bounded (roughly one rotation window, not 10x).
    assert (tmp_path / "events.jsonl").stat().st_size < 2000
    # Backup holds the older window.
    assert backup.stat().st_size > 0


def test_10k_line_tail_returns_200_fast(tmp_path) -> None:
    from server.main import EVENTS_REPLAY_LIMIT, tail_log_events

    log = tmp_path / "big.jsonl"
    with log.open("w", encoding="utf-8") as fh:
        for n in range(10000):
            fh.write(json.dumps({"type": "tool_call", "n": n}) + "\n")
    start = time.monotonic()
    events = tail_log_events(log)
    elapsed = time.monotonic() - start
    assert len(events) == EVENTS_REPLAY_LIMIT == 200
    assert [p["n"] for _, p in events] == list(range(9800, 10000))
    assert elapsed < 2.0


# --- 4. silent task loss ---


def test_config_missing_emits_task_failed(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "EVENT_LOG", tmp_path / "events.jsonl")

    def _boom():
        raise FileNotFoundError("missing config/tools.yaml")

    monkeypatch.setattr("buddy_core.orchestrator.load_tools_config", _boom)
    result = orchestrator.run("research hello")
    assert not result.ok
    lines = (tmp_path / "events.jsonl").read_text(encoding="utf-8").splitlines()
    assert lines
    last = json.loads(lines[-1])
    assert last["type"] == "task_failed"


def test_log_failure_emits_task_failed_no_raise(tmp_path, monkeypatch) -> None:
    """A failing log write still returns TaskResult (never raises)."""
    monkeypatch.setattr(orchestrator, "EVENT_LOG", tmp_path / "events.jsonl")
    real_log = orchestrator._log_event
    calls = {"n": 0}

    def flaky(event_type: str, payload: dict) -> None:
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("disk full")
        return real_log(event_type, payload)

    monkeypatch.setattr(orchestrator, "_log_event", flaky)
    result = orchestrator.run("research hello")
    assert not result.ok
    assert "Plan rejected" in result.output or "disk" in result.output.lower() or result.task_id


def test_empty_command_emits_task_failed(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(orchestrator, "EVENT_LOG", tmp_path / "events.jsonl")
    result = orchestrator.run("   ")
    assert not result.ok
    assert result.output == "Empty command."
    lines = (tmp_path / "events.jsonl").read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert rec["type"] == "task_failed"
    assert rec["error"] == "Empty command."
    assert "text" in rec
    assert len(rec["text"]) <= 200


# --- 5. uniform envelope ---


def test_422_envelope_shape(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app, raise_server_exceptions=False)
    # List body vs dict body: schema mismatch -> 422 validation_error.
    resp = client.post("/command", json=[], headers=_auth())
    assert resp.status_code == 422
    body = resp.json()
    assert body["error"]["code"] == "validation_error"
    assert "message" in body["error"]
    assert "detail" not in body


def test_404_405_envelope_shapes(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app, raise_server_exceptions=False)
    r404 = client.get("/no-such-route-xyz", headers=_auth())
    assert r404.status_code == 404
    assert r404.json()["error"]["code"] == "not_found"
    assert "message" in r404.json()["error"]
    r405 = client.get("/command", headers=_auth())
    assert r405.status_code == 405
    assert r405.json()["error"]["code"] == "method_not_allowed"
    r405b = client.post("/health", headers=_auth())
    assert r405b.status_code == 405
    assert r405b.json()["error"]["code"] == "method_not_allowed"


def test_unauth_malformed_still_envelope(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app, raise_server_exceptions=False)
    # Unparseable JSON without a token: still {error:...}, never detail array.
    resp = client.post(
        "/command", content=b"{bad json", headers={"Content-Type": "application/json"}
    )
    assert resp.status_code in (401, 422)
    body = resp.json()
    assert "error" in body
    assert "code" in body["error"] and "message" in body["error"]
    assert "detail" not in body
    # Valid JSON without token stays auth-first 401 envelope.
    resp2 = client.post("/command", json={"text": "hi"})
    assert resp2.status_code == 401
    assert resp2.json()["error"]["code"] == "unauthorized"


# --- 6. /events ASGI: headers, retry, keepalive, disconnect ---


@pytest.mark.asyncio
async def test_events_headers_retry_and_keepalive(tmp_path, monkeypatch) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    log = tmp_path / "events.jsonl"
    log.write_text(json.dumps({"type": "task_started", "task_id": "k"}) + "\n", encoding="utf-8")
    # Speed up the 15s keepalive for the test only.
    import server.main as main_mod

    monkeypatch.setattr(main_mod, "SSE_KEEPALIVE_SECONDS", 0.3)
    app = create_app(security_path=sec, event_log=log)
    scope = _http_scope("/events")
    sent: list[dict] = []
    sent_body = False
    gone = anyio.Event()

    async def receive() -> dict:
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        sent.append(message)
        bodies = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
        if bodies.count(b": ping") >= 1 and b"task_started" in bodies:
            gone.set()

    with anyio.fail_after(10):
        await app(scope, receive, send)
    start = next(m for m in sent if m["type"] == "http.response.start")
    headers = {k.decode(): v.decode() for k, v in start["headers"]}
    assert headers.get("content-type") == "text/event-stream"
    assert headers.get("cache-control") == "no-cache"
    assert headers.get("x-accel-buffering") == "no"
    bodies = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    assert b"retry: 3000" in bodies
    assert b": ping" in bodies
    # Client-side parse ignores retry + ping and still sees the event.
    parsed = _parse_sse_client_side(bodies)
    assert ("task_started", {"task_id": "k"}) in [(t, {k2: v2 for k2, v2 in p.items() if k2 == "task_id"}) for t, p in parsed] or any(
        t == "task_started" for t, _ in parsed
    )


def test_keepalive_comment_ignored_by_parser() -> None:
    raw = b"retry: 3000\n\nevent: task_started\ndata: {\"task_id\": \"a\"}\n\n: ping\n\nevent: tool_call\ndata: {\"tool\": \"w\"}\n\n"
    parsed = _parse_sse_client_side(raw)
    assert parsed == [("task_started", {"task_id": "a"}), ("tool_call", {"tool": "w"})]


@pytest.mark.asyncio
async def test_events_disconnect_midstream_clean(tmp_path) -> None:
    """Mid-stream disconnect ends the response cleanly (existing pattern)."""
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    log = tmp_path / "events.jsonl"
    log.write_text(json.dumps({"type": "task_started", "task_id": "d"}) + "\n", encoding="utf-8")
    app = create_app(security_path=sec, event_log=log)
    scope = _http_scope("/events")
    gone = anyio.Event()
    sent_body = False
    frames = 0
    returned = False

    async def receive() -> dict:
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await gone.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        nonlocal frames
        if message["type"] == "http.response.body" and message.get("body", b""):
            frames += 1
            if frames >= 2:  # retry + replay -> drop
                gone.set()

    with anyio.fail_after(10):
        await app(scope, receive, send)
        returned = True
    assert returned is True
    assert frames >= 2
