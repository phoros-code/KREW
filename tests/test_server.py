"""Tests for server/main.py — TestClient routing/auth/proximity, no real network."""

import json
from datetime import datetime, timezone

import pytest
import yaml
from fastapi.testclient import TestClient

from buddy_core import orchestrator
from server.main import create_app, format_sse, get_proximity, iter_log_events, tail_log_events

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


def test_proximity_config_needs_token(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.get("/proximity")
    assert resp.status_code == 401


def test_proximity_config_shape(app_lan) -> None:
    """Phase 4.2: phone fetches mode + threshold once after pairing."""
    client = TestClient(app_lan)
    resp = client.get("/proximity", headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["mode"] == "lan_only"
    assert body["rssi_near_threshold"] == -60
    assert "token" not in resp.text  # non-sensitive by construction


def test_proximity_config_readable_in_far_mode(app_bt) -> None:
    """The indicator needs the threshold MOST when far — far still gets 200."""
    client = TestClient(app_bt)
    resp = client.get("/proximity", headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 200
    assert resp.json()["mode"] == "lan_plus_bluetooth"
    # ...while a near-only endpoint from the same far client is still 403.
    assert client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer {TOKEN}"}).status_code == 403


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
    calls: list[tuple[str, str, str]] = []
    def _fake_run(text, task_id=None, source="text"):
        calls.append((text, task_id, source))
        return orchestrator.TaskResult(ok=True, output="done", task_id=task_id or "x")
    monkeypatch.setattr(orchestrator, "run", _fake_run)
    client = TestClient(app_lan)
    resp = client.post("/command", json={"text": "hello"}, headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "queued" and body["task_id"]
    assert calls and calls[0][0] == "hello" and calls[0][1] == body["task_id"]
    assert calls[0][2] == "text"  # API path is quality-first


def test_command_far_mode_forbidden(app_bt) -> None:
    client = TestClient(app_bt)
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"

def test_command_near_with_strong_rssi(app_bt, monkeypatch) -> None:
    monkeypatch.setattr(
        orchestrator,
        "run",
        lambda text, task_id=None, source="text": orchestrator.TaskResult(ok=True, output="d", task_id=task_id or "x"),
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


def test_tail_returns_trailing_slice_in_order(tmp_path) -> None:
    """Decision (4): reconnect replay is capped — last 200, oldest-first."""
    from server.main import EVENTS_REPLAY_LIMIT

    log = tmp_path / "e.jsonl"
    log.write_text(
        "".join(json.dumps({"type": "tool_call", "n": n}) + "\n" for n in range(250)),
        encoding="utf-8",
    )
    events = tail_log_events(log)
    assert len(events) == EVENTS_REPLAY_LIMIT == 200
    assert [p["n"] for _, p in events] == list(range(50, 250))


def test_tail_short_log_returns_everything_oldest_first(tmp_path) -> None:
    log = tmp_path / "e.jsonl"
    log.write_text('{"type": "a"}\n{"type": "b"}\n', encoding="utf-8")
    assert [e[0] for e in tail_log_events(log)] == ["a", "b"]


def test_tail_skips_junk_and_missing_file(tmp_path) -> None:
    log = tmp_path / "e.jsonl"
    log.write_text('{"type": "a"}\nnot-json\n\n{"type": "b"}\n', encoding="utf-8")
    assert [e[0] for e in tail_log_events(log)] == ["a", "b"]
    assert tail_log_events(tmp_path / "nope.jsonl") == []


def test_tail_rejects_nonpositive_limit(tmp_path) -> None:
    from server.main import EVENTS_REPLAY_LIMIT

    log = tmp_path / "e.jsonl"
    log.write_text('{"type": "a"}\n', encoding="utf-8")
    assert tail_log_events(log, limit=0) == tail_log_events(log, limit=EVENTS_REPLAY_LIMIT)


def test_format_sse_shape() -> None:
    out = format_sse("task_started", {"task_id": "x"})
    assert out.startswith("event: task_started\ndata: ")
    assert json.loads(out.split("data: ", 1)[1]) == {"task_id": "x"}


def test_screen_needs_auth_and_consent(app_lan) -> None:
    client = TestClient(app_lan)
    assert client.get("/screen").status_code == 401
    # Authenticated but no consent grant -> fail closed (consent_required, not 501).
    resp = client.get("/screen", headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "consent_required"


def test_proximity_threshold_needs_token(app_lan) -> None:
    client = TestClient(app_lan)
    resp = client.post("/proximity/threshold", json={"rssi_near_threshold": -65})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


def test_proximity_threshold_far_forbidden(app_bt) -> None:
    client = TestClient(app_bt)
    auth = {"Authorization": f"Bearer {TOKEN}"}
    # No X-RSSI in lan_plus_bluetooth -> far -> 403 (same shape as /command).
    resp = client.post("/proximity/threshold", json={"rssi_near_threshold": -65}, headers=auth)
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"
    # A weak/absent signal is far too — below the -60 default threshold.
    resp = client.post(
        "/proximity/threshold",
        json={"rssi_near_threshold": -65},
        headers={**auth, "X-RSSI": "-80"},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"


def test_proximity_threshold_rejects_out_of_range(app_lan) -> None:
    client = TestClient(app_lan)
    auth = {"Authorization": f"Bearer {TOKEN}"}  # lan_only: near without X-RSSI
    for bad in (-20, -120, "nonsense", 12.5):
        resp = client.post("/proximity/threshold", json={"rssi_near_threshold": bad}, headers=auth)
        assert resp.status_code == 400, bad
        assert resp.json()["error"]["code"] == "bad_request"
    # Missing key -> 400, not 422.
    resp = client.post("/proximity/threshold", json={}, headers=auth)
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"
    # Strict-int choice: numeric strings (even parseable ones), bools
    # (subclass of int), and null are all rejected — no coercion ambiguity.
    for bad in ("-65", True, False, None):
        resp = client.post("/proximity/threshold", json={"rssi_near_threshold": bad}, headers=auth)
        assert resp.status_code == 400, bad
        assert resp.json()["error"]["code"] == "bad_request"


def test_proximity_threshold_updates_and_persists(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    _security(sec, "lan_plus_bluetooth")
    log = tmp_path / "events.jsonl"
    app = create_app(security_path=sec, event_log=log)
    client = TestClient(app)
    near = {"Authorization": f"Bearer {TOKEN}", "X-RSSI": "-50"}
    resp = client.post("/proximity/threshold", json={"rssi_near_threshold": -65}, headers=near)
    assert resp.status_code == 200
    assert resp.json() == {"mode": "lan_plus_bluetooth", "rssi_near_threshold": -65}
    # Same process, no restart: GET reflects the new value.
    resp = client.get("/proximity", headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 200
    assert resp.json()["rssi_near_threshold"] == -65
    # On disk: threshold updated, every other key preserved.
    on_disk = yaml.safe_load(sec.read_text(encoding="utf-8"))
    assert on_disk["proximity"]["rssi_near_threshold"] == -65
    assert on_disk["proximity"]["mode"] == "lan_plus_bluetooth"
    assert on_disk["auth"]["token"] == TOKEN
    # Survives restart: a fresh app on the same file serves the new value.
    app2 = create_app(security_path=sec, event_log=log)
    resp2 = TestClient(app2).get("/proximity", headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp2.json()["rssi_near_threshold"] == -65


def test_expired_token_gets_scoped_401_code(tmp_path) -> None:
    """Absolute ceiling surfaces per-connection as 401 token_expired.

    The expiring device learns to re-pair from THIS response — it must not
    depend on ever seeing the broadcast SSE frame (which itself needs auth).
    """
    from datetime import datetime, timedelta, timezone

    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    data = yaml.safe_load(sec.read_text(encoding="utf-8"))
    data["auth"]["issued_at"] = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    sec.write_text(yaml.safe_dump(data), encoding="utf-8")
    app = create_app(security_path=sec, event_log=tmp_path / "events.jsonl")
    client = TestClient(app)
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "token_expired"
    # Wrong token still gets the generic code (no expiry oracle).
    resp = client.post("/command", json={"text": "hi"}, headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"
