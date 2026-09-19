"""Tests for server/main.py — TestClient routing/auth/proximity, no real network."""

import json

import pytest
import yaml
from fastapi.testclient import TestClient

from buddy_core import orchestrator
from server.main import create_app, format_sse, get_proximity, iter_log_events

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
    log = tmp_path / "events.jsonl"
    log.write_text(
        json.dumps({"type": "task_started", "task_id": "a", "text": "hi"}) + "\n", encoding="utf-8"
    )
    return create_app(security_path=sec, event_log=log)


@pytest.fixture()
def app_bt(tmp_path):
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_plus_bluetooth")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


def test_health_unauthenticated_and_minimal(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_command_requires_token(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.post("/command", json={"text": "hi"})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


def test_command_bad_token_rejected(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


def test_command_queued_near(app_lan, monkeypatch) -> None:
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        orchestrator, "run", lambda text, task_id=None: calls.append((text, task_id))
        or orchestrator.TaskResult(ok=True, output="done", task_id=task_id or "x"),
    )
    client = TestClient(app_lan)
    resp = client.post("/command", json={"text": "hello"}, headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "queued" and body["task_id"]
    assert calls and calls[0][0] == "hello" and calls[0][1] == body["task_id"]


def test_command_far_mode_forbidden(app_bt) -> None:
    client = TestClient(app_bt)
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"


def test_command_near_with_strong_rssi(app_bt, monkeypatch) -> None:
    monkeypatch.setattr(
        orchestrator, "run", lambda text, task_id=None: orchestrator.TaskResult(ok=True, output="d", task_id=task_id or "x")
    )
    client = TestClient(app_bt)
    resp = client.post(
        "/command",
        json={"text": "hi"},
        headers={"Authorization": f"Bearer {TOKEN}", "X-RSSI": "-50"},
    )
    assert resp.status_code == 200


def test_events_rejects_unauthenticated(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.get("/events")
    assert resp.status_code == 401


def test_proximity_fail_closed() -> None:
    assert get_proximity({"mode": "lan_only"}) == "near"
    bt = {"mode": "lan_plus_bluetooth", "rssi_near_threshold": -60}
    assert get_proximity(bt, None) == "far"          # missing signal
    assert get_proximity(bt, -80) == "far"           # weak signal
    assert get_proximity(bt, -50) == "near"          # strong signal
    assert get_proximity(bt, "garbage") == "far"     # unparseable


def test_iter_log_events_skips_junk(tmp_path) -> None:
    log = tmp_path / "e.jsonl"
    log.write_text(
        '{"type": "task_started", "task_id": "1"}\n\nnot-json\n{"type": "tool_call", "tool": "web_search"}\n',
        encoding="utf-8",
    )
    events = list(iter_log_events(log))
    assert [e[0] for e in events] == ["task_started", "tool_call"]


def test_format_sse_shape() -> None:
    out = format_sse("task_started", {"task_id": "x"})
    assert out.startswith("event: task_started\ndata: ")
    assert json.loads(out.split("data: ", 1)[1]) == {"task_id": "x"}


def test_screen_stub_needs_auth_and_is_near_gated(app_lan) -> None:
    client = TestClient(app_lan)
    assert client.get("/screen").status_code == 401
    resp = client.get("/screen", headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 501  # Phase 3 implements the MJPEG stream
