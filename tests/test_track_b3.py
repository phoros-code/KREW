"""Track B3 (plans reach shell/files + memory + destructive-op consent) tests.

Covers: per-category scope matrix + executor runtime refusals, jail at plan
time, allowlisted shell executes / non-allowlisted pauses for consent,
overwrite pauses (approve executes, deny/timeout fail closed), the ops
consent queue (idempotent create, laptop-only approve/deny, real-manager
interop with the executor poll), bounded memory (cap/recall/forget/prompt
context/no raw content), delegate still refused, and the /ops/* HTTP
surface (validation, auth, proximity).
"""

from __future__ import annotations

import json
import threading
import time
from datetime import datetime, timezone

import pytest
import yaml
from fastapi.testclient import TestClient

import buddy_core.orchestrator as orch
from buddy_core.agents import executor as exec_mod
from buddy_core.agents.executor import (
    AGENT_TOOL_SCOPES,
    CONSENT_NEEDED_PREFIX,
    EXECUTOR_TOOLS,
    execute_plan,
    ops_poll_for_sha,
    ops_request_for_sha,
    scope_allows,
)
from buddy_core.agents.planner import (
    KNOWN_TOOLS,
    Plan,
    PlanRejected,
    ToolCall,
    _planner_system_prompt,
    build_llm_plan,
    validate_plan,
)
from buddy_core.config import AgentLimits, FilesConfig, MemoryConfig
from buddy_core.memory.memory import (
    MEMORY_CONTEXT_CHARS,
    MemoryStore,
    format_memories_for_prompt,
)

LIMITS = AgentLimits(max_plan_steps=3, max_recursion_depth=1, tool_timeout_seconds=5)
TOKEN = "test-token-b3"
APPROVAL_SECRET = "b3" * 32  # 64-hex deterministic


def _tools_cfg(tmp_path, memory_name: str = "memory.jsonl", cap: int = 500):
    """Real shell allowlist/denylist + tmp workspace + tmp memory store."""
    from buddy_core.config import load_tools_config

    cfg = load_tools_config()
    cfg.files = FilesConfig(workspace_root=str(tmp_path / "ws"))
    cfg.memory = MemoryConfig(path=str(tmp_path / memory_name), cap=cap)
    cfg.agent_limits = LIMITS
    return cfg


def _emit(events: list):
    def _record(event_type: str, payload: dict) -> None:
        events.append((event_type, payload))

    return _record


class _FakePlannerClient:
    def __init__(self, text: str):
        self._text = text
        self.seen: dict = {}

    def list(self):
        return {"models": [{"name": "llama3.1:8b"}]}

    def chat(self, model, messages, options=None):
        self.seen["model"] = model
        self.seen["messages"] = messages
        return {"message": {"content": self._text}}


class FakeOpsManager:
    """Duck-typed ops queue (start_consent_request/status_of/approve/deny)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._records: dict[str, str] = {}
        self._n = 0

    def start_consent_request(self) -> str:
        with self._lock:
            self._n += 1
            cid = f"op-{self._n}"
            self._records[cid] = "pending"
            return cid

    def status_of(self, cid: str):
        with self._lock:
            return self._records.get(cid)

    def approve(self, cid: str) -> bool:
        with self._lock:
            if self._records.get(cid) == "pending":
                self._records[cid] = "approved"
                return True
            return self._records.get(cid) == "approved"

    def deny(self, cid: str) -> bool:
        with self._lock:
            if self._records.get(cid) == "pending":
                self._records[cid] = "denied"
                return True
            return self._records.get(cid) == "denied"

    def wait_for_pending(self, timeout: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                for cid, status in self._records.items():
                    if status == "pending":
                        return cid
            time.sleep(0.01)
        raise AssertionError("no pending ops request appeared")


# --- 1. scope matrix -------------------------------------------------------


def test_scope_matrix_matches_spec() -> None:
    expected = {
        "coder": {"write_file", "read_file", "list_dir"},
        "executor": {"shell"},
        "researcher": {"web_search", "fetch_page"},
        "planner": set(),
    }
    assert {k: set(v) for k, v in AGENT_TOOL_SCOPES.items()} == expected
    universe = set(KNOWN_TOOLS) | {"launch_app", "list_apps"}
    for category, allowed in expected.items():
        for tool in universe:
            assert scope_allows(category, tool) == (tool in allowed), (category, tool)
    # Unknown categories deny everything; delegate is denied everywhere
    # (multi-agent delegation executes in a later track).
    for tool in universe:
        assert scope_allows("no-such-agent", tool) is False
        assert scope_allows("coder", "delegate") is False
        assert scope_allows("executor", "delegate") is False


def test_executor_runtime_scope_unchanged() -> None:
    assert EXECUTOR_TOOLS == {"shell", "read_file", "write_file", "list_dir"}


def test_executor_refuses_out_of_runtime_scope(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    cases = [
        ToolCall("launch_app", {"app_key": "notepad"}),
        ToolCall("web_search", {"query": "hi"}),
        ToolCall("fetch_page", {"url": "https://example.com"}),
        ToolCall("list_apps", {}),
    ]
    for step in cases:
        validate_plan(Plan(steps=[step]), LIMITS)  # planner allows globally...
        result = execute_plan(Plan(steps=[step]), tools, "t-scope", _emit([]))
        assert not result.ok  # ...but the executor refuses (scope)
        assert "outside executor scope" in result.output


def test_unknown_tool_rejected_before_execution(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("rm_rf_everything", {})])
    with pytest.raises(PlanRejected):
        validate_plan(plan, LIMITS)
    result = execute_plan(plan, tools, "t-unknown", _emit([]))
    assert not result.ok
    assert "Plan rejected" in result.output


# --- 2. jail at plan time --------------------------------------------------


def test_jail_rejects_traversal_at_plan_time(tmp_path) -> None:
    files_cfg = FilesConfig(workspace_root=str(tmp_path / "ws"))
    for tool, args in (
        ("read_file", {"path": "../evil.txt"}),
        ("list_dir", {"path": "../.."}),
        ("write_file", {"path": "../evil.txt", "content": "x"}),
        ("read_file", {"path": "/absolutely/not/here.txt"}),
    ):
        with pytest.raises(PlanRejected, match="[Ww]orkspace"):
            validate_plan(Plan(steps=[ToolCall(tool, args)]), LIMITS, files_cfg)


def test_same_plan_passes_schema_without_jail_config() -> None:
    """Proves the jail check (not the shape check) rejects — opt-in only."""
    plan = Plan(steps=[ToolCall("read_file", {"path": "../evil.txt"})])
    validate_plan(plan, LIMITS)  # no files_cfg → schema only → passes


def test_build_llm_plan_rejects_traversal_path(tmp_path) -> None:
    from buddy_core.config import ModelsConfig

    text = '{"steps": [{"tool": "read_file", "args": {"path": "../evil.txt"}}]}'
    client = _FakePlannerClient(text)
    cfg = _tools_cfg(tmp_path)
    models = ModelsConfig()
    with pytest.raises(PlanRejected, match="[Ww]orkspace"):
        build_llm_plan("read the file", cfg, models, client=client)


def test_build_llm_plan_accepts_safe_file_steps(tmp_path) -> None:
    from buddy_core.config import ModelsConfig

    text = '{"steps": [{"tool": "list_dir", "args": {"path": "."}}]}'
    client = _FakePlannerClient(text)
    plan = build_llm_plan("list files", _tools_cfg(tmp_path), ModelsConfig(), client=client)
    assert plan.steps[0].tool == "list_dir"


# --- 3. shell: allowlisted executes, rest pauses ---------------------------


def test_shell_allowlisted_executes(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "git --version"})])
    result = execute_plan(plan, tools, "t-sh-ok", _emit([]))
    assert result.ok
    assert "git version" in result.output.lower()


def test_shell_non_allowlisted_pauses_for_consent(tmp_path) -> None:
    """Not allowlisted, not denylisted — still pauses (no silent fallback)."""
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "curl http://example.com"})])
    events: list = []
    result = execute_plan(plan, tools, "t-sh-pause", _emit(events))
    assert not result.ok
    assert result.output.startswith(CONSENT_NEEDED_PREFIX)
    assert result.steps_taken == 0
    # The attempt is still observable (redacted) — the phone sees the pause.
    assert events and events[0][0] == "tool_call"
    assert events[0][1]["tool"] == "shell"


def test_shell_denylist_pauses_with_reason(tmp_path) -> None:
    """Denylisted commands pause AND keep the denial reason (baseline compat)."""
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "rm -rf /tmp/whatever"})])
    result = execute_plan(plan, tools, "t-sh-deny", _emit([]))
    assert not result.ok
    assert result.output.startswith(CONSENT_NEEDED_PREFIX)
    assert "enylist" in result.output  # "Blocked by denylist" preserved


def test_shell_approval_never_expands_allowlist(tmp_path) -> None:
    """Laptop approval authorizes within policy — the allowlist stays absolute."""
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "curl http://example.com"})])
    result = execute_plan(plan, tools, "t-sh-appr", _emit([]), consent_checker=lambda rec: True)
    assert not result.ok
    assert "allowlist" in result.output.lower()


def test_checker_exception_fails_closed(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "curl http://example.com"})])

    def _boom(record):
        raise RuntimeError("checker blew up")

    result = execute_plan(plan, tools, "t-sh-boom", _emit([]), consent_checker=_boom)
    assert not result.ok
    assert result.output.startswith(CONSENT_NEEDED_PREFIX)


# --- 4. overwrite pauses / approves ----------------------------------------


def test_write_fresh_file_executes_without_consent(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("write_file", {"path": "new.txt", "content": "hi"})])
    result = execute_plan(plan, tools, "t-w-fresh", _emit([]))
    assert result.ok
    assert (tmp_path / "ws" / "new.txt").read_text() == "hi"


def test_overwrite_pauses_without_approval(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "victim.txt").write_text("v1")
    plan = Plan(steps=[ToolCall("write_file", {"path": "victim.txt", "content": "v2"})])
    result = execute_plan(plan, tools, "t-w-pause", _emit([]))
    assert not result.ok
    assert result.output.startswith(CONSENT_NEEDED_PREFIX)
    assert (tmp_path / "ws" / "victim.txt").read_text() == "v1"  # untouched


def test_overwrite_executes_with_approval(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "victim.txt").write_text("v1")
    plan = Plan(steps=[ToolCall("write_file", {"path": "victim.txt", "content": "v2"})])
    result = execute_plan(plan, tools, "t-w-ok", _emit([]), consent_checker=lambda rec: True)
    assert result.ok
    assert (tmp_path / "ws" / "victim.txt").read_text() == "v2"


def test_jail_escape_write_still_rejected_not_paused(tmp_path) -> None:
    """Outside-jail writes bypass the consent hook — rejected outright."""
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("write_file", {"path": "../evil.txt", "content": "x"})])
    result = execute_plan(plan, tools, "t-w-jail", _emit([]), consent_checker=lambda rec: True)
    assert not result.ok
    assert CONSENT_NEEDED_PREFIX not in result.output
    assert "workspace" in result.output.lower()


# --- 5. ops queue: identity + poll semantics --------------------------------


def test_op_record_is_redacted_and_deterministic() -> None:
    args = {"path": "a.txt", "content": "super-secret-body"}
    rec1 = exec_mod.op_record_for_step("write_file", args)
    rec2 = exec_mod.op_record_for_step("write_file", dict(args))
    assert rec1["sha"] == rec2["sha"]
    assert len(rec1["sha"]) == 64 and all(c in "0123456789abcdef" for c in rec1["sha"])
    # Redacted: no raw body anywhere in the record.
    raw = json.dumps(rec1)
    assert "super-secret-body" not in raw
    assert rec1["args"]["content"]["sha256"]
    # The caller's dict is untouched (plan still executes with full values).
    assert args["content"] == "super-secret-body"


def test_ops_request_idempotent_while_pending_or_approved() -> None:
    mgr = FakeOpsManager()
    first = ops_request_for_sha(mgr, "a" * 64, "write_file")
    assert ops_request_for_sha(mgr, "a" * 64, "write_file") == first
    mgr.approve(first)
    assert ops_request_for_sha(mgr, "a" * 64, "write_file") == first  # reuse grant


def test_ops_request_replaces_decided_entry() -> None:
    mgr = FakeOpsManager()
    first = ops_request_for_sha(mgr, "b" * 64, "shell")
    mgr.deny(first)
    second = ops_request_for_sha(mgr, "b" * 64, "shell")
    assert second != first
    assert mgr.status_of(second) == "pending"


def test_ops_poll_approved_deny_and_timeout() -> None:
    mgr = FakeOpsManager()
    cid = ops_request_for_sha(mgr, "c" * 64, "shell")
    assert ops_poll_for_sha(mgr, "c" * 64, "shell", timeout_seconds=0) is False  # still pending
    mgr.approve(cid)
    assert ops_poll_for_sha(mgr, "c" * 64, "shell", timeout_seconds=0) is True
    cid2 = ops_request_for_sha(mgr, "d" * 64, "shell")
    mgr.deny(cid2)
    assert ops_poll_for_sha(mgr, "d" * 64, "shell", timeout_seconds=5) is False  # immediate
    # Pending with a tiny budget fails closed fast (no 60s sleep in tests).
    started = time.monotonic()
    assert ops_poll_for_sha(mgr, "e" * 64, "shell", timeout_seconds=0.05, poll_interval=0.01) is False
    assert time.monotonic() - started < 2.0


def test_ops_approve_during_poll_executes(tmp_path) -> None:
    """Full loop with fakes: pause → laptop approve → executes."""
    tools = _tools_cfg(tmp_path)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "doc.txt").write_text("v1")
    plan = Plan(steps=[ToolCall("write_file", {"path": "doc.txt", "content": "v2"})])
    mgr = FakeOpsManager()
    checker = lambda rec: ops_poll_for_sha(  # noqa: E731
        mgr, rec["sha"], rec["tool"], timeout_seconds=5.0, poll_interval=0.01
    )
    results: dict = {}

    def _target():
        results["r"] = execute_plan(plan, tools, "t-loop-ok", _emit([]), consent_checker=checker)

    thread = threading.Thread(target=_target, daemon=True)
    thread.start()
    try:
        cid = mgr.wait_for_pending()
        assert mgr.approve(cid) is True
    finally:
        thread.join(timeout=10)
    assert not thread.is_alive()
    assert results["r"].ok
    assert (tmp_path / "ws" / "doc.txt").read_text() == "v2"


def test_ops_deny_during_poll_refuses(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "doc.txt").write_text("v1")
    plan = Plan(steps=[ToolCall("write_file", {"path": "doc.txt", "content": "v2"})])
    mgr = FakeOpsManager()
    checker = lambda rec: ops_poll_for_sha(  # noqa: E731
        mgr, rec["sha"], rec["tool"], timeout_seconds=5.0, poll_interval=0.01
    )
    results: dict = {}

    def _target():
        results["r"] = execute_plan(plan, tools, "t-loop-deny", _emit([]), consent_checker=checker)

    thread = threading.Thread(target=_target, daemon=True)
    thread.start()
    try:
        cid = mgr.wait_for_pending()
        assert mgr.deny(cid) is True
    finally:
        thread.join(timeout=10)
    assert not thread.is_alive()
    assert not results["r"].ok
    assert results["r"].output.startswith(CONSENT_NEEDED_PREFIX)
    assert (tmp_path / "ws" / "doc.txt").read_text() == "v1"


# --- 6. orchestrator: execute / fallback / memory ---------------------------


def _orch_tools(monkeypatch, tmp_path, memory_name="memory.jsonl"):
    cfg = _tools_cfg(tmp_path, memory_name)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr("buddy_core.orchestrator.load_tools_config", lambda: cfg)
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    return cfg


def test_orchestrator_llm_shell_plan_executes(monkeypatch, tmp_path) -> None:
    _orch_tools(monkeypatch, tmp_path)

    def _fake_plan(command, tools_cfg, models, memories=None):
        return Plan(steps=[ToolCall("shell", {"command": "git --version"})])

    monkeypatch.setattr("buddy_core.orchestrator.build_llm_plan", _fake_plan)
    result = orch.run("check git version")
    assert result.ok
    assert "git version" in result.output.lower()
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert events[-1]["type"] == "task_completed"
    assert events[-1].get("planner") == "llm"


def test_orchestrator_llm_traversal_plan_falls_back(monkeypatch, tmp_path) -> None:
    """A traversal LLM plan is jail-rejected → deterministic fallback (planner=fallback)."""

    class _Down:
        def __init__(self, *a, **k):
            raise ConnectionError("refused")

    _orch_tools(monkeypatch, tmp_path)
    monkeypatch.setattr("ollama.Client", _Down)

    def _evil_plan(command, tools_cfg, models, memories=None):
        return Plan(steps=[ToolCall("list_dir", {"path": "../../etc"})])

    monkeypatch.setattr("buddy_core.orchestrator.build_llm_plan", _evil_plan)
    result = orch.run("list files please")
    assert not result.ok  # fallback research reports Ollama down
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert events[-1].get("planner") == "fallback"
    assert not (tmp_path / "evil-probe.txt").exists()


def test_orchestrator_destructive_pauses_without_ops(monkeypatch, tmp_path) -> None:
    cfg = _orch_tools(monkeypatch, tmp_path)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "notes.txt").write_text("original")

    def _overwrite_plan(command, tools_cfg, models, memories=None):
        return Plan(steps=[ToolCall("write_file", {"path": "notes.txt", "content": "clobbered"})])

    monkeypatch.setattr("buddy_core.orchestrator.build_llm_plan", _overwrite_plan)
    result = orch.run("overwrite my notes")
    assert not result.ok
    assert result.output.startswith(CONSENT_NEEDED_PREFIX)
    assert (tmp_path / "ws" / "notes.txt").read_text() == "original"
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert events[-1].get("planner") == "llm"
    _ = cfg


def test_orchestrator_ops_approval_executes(monkeypatch, tmp_path) -> None:
    _orch_tools(monkeypatch, tmp_path)
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "notes.txt").write_text("original")

    def _overwrite_plan(command, tools_cfg, models, memories=None):
        return Plan(steps=[ToolCall("write_file", {"path": "notes.txt", "content": "approved-edit"})])

    monkeypatch.setattr("buddy_core.orchestrator.build_llm_plan", _overwrite_plan)
    mgr = FakeOpsManager()
    results: dict = {}

    def _target():
        results["r"] = orch.run("overwrite my notes", ops_consent=mgr)

    thread = threading.Thread(target=_target, daemon=True)
    thread.start()
    try:
        cid = mgr.wait_for_pending()
        mgr.approve(cid)
    finally:
        thread.join(timeout=15)
    assert not thread.is_alive()
    assert results["r"].ok
    assert (tmp_path / "ws" / "notes.txt").read_text() == "approved-edit"


def test_orchestrator_remembers_redacted_task_lifecycle(monkeypatch, tmp_path) -> None:
    _orch_tools(monkeypatch, tmp_path, "lifecycle.jsonl")

    def _fake_plan(command, tools_cfg, models, memories=None):
        return Plan(steps=[ToolCall("list_dir", {"path": "."})])

    monkeypatch.setattr("buddy_core.orchestrator.build_llm_plan", _fake_plan)
    result = orch.run("list my files")
    assert result.ok
    entries = [
        json.loads(line) for line in (tmp_path / "lifecycle.jsonl").read_text().splitlines()
    ]
    kinds = [e["kind"] for e in entries]
    assert "task_started" in kinds and "task_completed" in kinds
    assert entries[0]["text"] == "list my files"
    assert "ok=True" in entries[-1]["text"]


def test_orchestrator_memory_never_stores_file_contents(monkeypatch, tmp_path) -> None:
    """A read_file step must not leak the file body into the memory store."""
    marker = "B3_MARKER_SECRET_7f3a9c1d4e5b"
    _orch_tools(monkeypatch, tmp_path, "nomarker.jsonl")
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    (tmp_path / "ws" / "secret.txt").write_text(f"classified {marker} payload")

    def _read_plan(command, tools_cfg, models, memories=None):
        return Plan(steps=[ToolCall("read_file", {"path": "secret.txt"})])

    monkeypatch.setattr("buddy_core.orchestrator.build_llm_plan", _read_plan)
    result = orch.run("read my secret file")
    assert result.ok
    assert marker in result.output  # the task itself sees the file...
    raw = (tmp_path / "nomarker.jsonl").read_bytes()
    assert marker.encode() not in raw  # ...but memory stores metadata only


# --- 7. memory store --------------------------------------------------------


def test_memory_cap_evicts_oldest(tmp_path) -> None:
    store = MemoryStore(path=tmp_path / "m.jsonl", cap=3)
    for i in range(5):
        store.remember("task_completed", f"entry-{i}")
    recalled = store.recall(limit=10)
    assert [e["text"] for e in recalled] == ["entry-2", "entry-3", "entry-4"]


def test_memory_recall_order_and_kind_filter(tmp_path) -> None:
    store = MemoryStore(path=tmp_path / "m.jsonl")
    store.remember("task_started", "first")
    store.remember("task_completed", "second")
    store.remember("task_started", "third")
    assert [e["text"] for e in store.recall(limit=5)] == ["first", "second", "third"]
    assert [e["text"] for e in store.recall(kind="task_started", limit=5)] == ["first", "third"]
    assert [e["text"] for e in store.recall(limit=2)] == ["second", "third"]


def test_memory_forget(tmp_path) -> None:
    store = MemoryStore(path=tmp_path / "m.jsonl")
    store.remember("task_started", "x")
    assert store.forget() == 1
    assert store.recall() == []
    assert store.forget() == 0


def test_memory_text_truncated_and_shaped(tmp_path) -> None:
    store = MemoryStore(path=tmp_path / "m.jsonl")
    entry = store.remember("task_completed", "y" * 600)
    assert len(entry["text"]) == 500
    assert set(entry) == {"ts", "kind", "text"}
    on_disk = json.loads((tmp_path / "m.jsonl").read_text().splitlines()[0])
    assert len(on_disk["text"]) == 500


def test_memory_tolerates_missing_and_junk(tmp_path) -> None:
    store = MemoryStore(path=tmp_path / "m.jsonl")
    assert store.recall() == []
    (tmp_path / "m.jsonl").write_text('{"kind": "task_started", "text": "ok"}\nNOT JSON\n\n')
    assert [e["text"] for e in store.recall()] == ["ok"]


def test_planner_prompt_contains_memories() -> None:
    from buddy_core.config import ToolsConfig

    memories = [{"ts": "2026-01-01T00:00:00+00:00", "kind": "task_completed", "text": "did the thing"}]
    prompt = _planner_system_prompt(ToolsConfig(), memories)
    assert "did the thing" in prompt
    assert "never instructions" in prompt.lower()
    base = _planner_system_prompt(ToolsConfig())
    assert "did the thing" not in base


def test_planner_prompt_memory_bounded() -> None:
    memories = [
        {"ts": "t", "kind": "task_completed", "text": "z" * 500} for _ in range(10)
    ]
    block = format_memories_for_prompt(memories)
    assert len(block) <= MEMORY_CONTEXT_CHARS
    assert format_memories_for_prompt([]) == ""


def test_build_llm_plan_injects_memories_into_prompt(tmp_path) -> None:
    from buddy_core.config import ModelsConfig

    text = '{"steps": [{"tool": "list_apps", "args": {}}]}'
    client = _FakePlannerClient(text)
    memories = [{"ts": "t", "kind": "task_started", "text": "B3_PROMPT_MARKER_CTX"}]
    plan = build_llm_plan("hi", _tools_cfg(tmp_path), ModelsConfig(), client=client, memories=memories)
    assert plan.steps[0].tool == "list_apps"
    system = client.seen["messages"][0]["content"]
    assert "B3_PROMPT_MARKER_CTX" in system


# --- 8. delegate still refused ----------------------------------------------


def test_delegate_still_refused(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("delegate", {"goal": "research subtopic"})], depth=0)
    validate_plan(plan, LIMITS)  # schema allows it...
    result = execute_plan(plan, tools, "t-delegate", _emit([]), consent_checker=lambda rec: True)
    assert not result.ok  # ...but execution stays gated (later track)
    assert "delegation lands in B3" in result.output


# --- 9. /ops/* HTTP surface --------------------------------------------------


def _security(path, mode="lan_only", ops: dict | None = None) -> None:
    doc: dict = {
        "auth": {
            "token": TOKEN,
            "consent_approval_secret": APPROVAL_SECRET,
            "max_failed_attempts": 5,
            "lockout_minutes": 15,
            "idle_timeout_minutes": 60,
            "token_absolute_max_age_days": 30,
            "issued_at": datetime.now(timezone.utc).isoformat(),
        },
        "proximity": {"mode": mode, "rssi_near_threshold": -60, "fail_mode": "far"},
    }
    if ops is not None:
        doc["ops"] = ops
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


@pytest.fixture()
def app_ops(tmp_path):
    from server.main import create_app

    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


@pytest.fixture()
def app_ops_far(tmp_path):
    from server.main import create_app

    sec = tmp_path / "security.yaml"
    _security(sec, "lan_plus_bluetooth")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


def _auth(extra: dict | None = None) -> dict:
    headers = {"Authorization": f"Bearer {TOKEN}"}
    if extra:
        headers.update(extra)
    return headers


def _approval() -> dict:
    return _auth({"X-Buddy-Approval": APPROVAL_SECRET})


_OP_BODY = {"op": "write_file", "args_sha": "ab" * 32}


def test_ops_create_pending_shape(app_ops) -> None:
    client = TestClient(app_ops)
    resp = client.post("/ops/consent", json=_OP_BODY, headers=_auth())
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "pending" and body["consent_id"]


def test_ops_create_idempotent_same_sha(app_ops) -> None:
    client = TestClient(app_ops)
    first = client.post("/ops/consent", json=_OP_BODY, headers=_auth()).json()["consent_id"]
    second = client.post("/ops/consent", json=_OP_BODY, headers=_auth()).json()["consent_id"]
    assert first == second


def test_ops_create_validation_400(app_ops) -> None:
    client = TestClient(app_ops)
    for bad in (
        {},
        {"op": "write_file"},
        {"args_sha": "ab" * 32},
        {"op": "", "args_sha": "ab" * 32},
        {"op": "x" * 201, "args_sha": "ab" * 32},
        {"op": "write_file", "args_sha": "not-hex"},
        {"op": "write_file", "args_sha": "ab" * 31},
        {"op": 123, "args_sha": "ab" * 32},
    ):
        resp = client.post("/ops/consent", json=bad, headers=_auth())
        assert resp.status_code == 400, bad
        assert resp.json()["error"]["code"] == "bad_request"


def test_ops_create_needs_auth_and_near(app_ops, app_ops_far) -> None:
    assert TestClient(app_ops).post("/ops/consent", json=_OP_BODY).status_code == 401
    resp = TestClient(app_ops_far).post("/ops/consent", json=_OP_BODY, headers=_auth())
    assert resp.status_code == 403  # far mode, no X-RSSI → far
    assert resp.json()["error"]["code"] == "forbidden"


def test_ops_approve_phone_only_forbidden(app_ops) -> None:
    client = TestClient(app_ops)
    cid = client.post("/ops/consent", json=_OP_BODY, headers=_auth()).json()["consent_id"]
    resp = client.post(f"/ops/consent/{cid}/approve", headers=_auth())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "approval_forbidden"
    resp = client.post(f"/ops/consent/{cid}/deny", headers=_auth())
    assert resp.status_code == 403


def test_ops_approve_deny_lifecycle(app_ops) -> None:
    client = TestClient(app_ops)
    cid = client.post("/ops/consent", json=_OP_BODY, headers=_auth()).json()["consent_id"]
    resp = client.post(f"/ops/consent/{cid}/approve", headers=_approval())
    assert resp.status_code == 200
    assert resp.json() == {"consent_id": cid, "status": "approved"}
    # Idempotent re-approve.
    assert client.post(f"/ops/consent/{cid}/approve", headers=_approval()).status_code == 200
    # Deny after approve conflicts (deny never revokes).
    resp = client.post(f"/ops/consent/{cid}/deny", headers=_approval())
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "conflict"


def test_ops_deny_lifecycle(app_ops) -> None:
    client = TestClient(app_ops)
    cid = client.post("/ops/consent", json=_OP_BODY, headers=_auth()).json()["consent_id"]
    resp = client.post(f"/ops/consent/{cid}/deny", headers=_approval())
    assert resp.json() == {"consent_id": cid, "status": "denied"}
    # Approve after deny conflicts with the ops denial envelope.
    resp = client.post(f"/ops/consent/{cid}/approve", headers=_approval())
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "consent_denied"
    assert "Destructive operation" in resp.json()["error"]["message"]


def test_ops_unknown_consent_404(app_ops) -> None:
    client = TestClient(app_ops)
    assert (
        client.post("/ops/consent/does-not-exist/approve", headers=_approval()).status_code == 404
    )
    assert client.post("/ops/consent/does-not-exist/deny", headers=_approval()).status_code == 404


def test_ops_queue_interop_with_executor_poll(app_ops) -> None:
    """Server queue + executor poll agree (real ConsentManager, no fakes)."""
    client = TestClient(app_ops)
    rec = exec_mod.op_record_for_step("write_file", {"path": "a.txt", "content": "x"})
    mgr = app_ops.state.ops_consent
    cid = ops_request_for_sha(mgr, rec["sha"], "write_file")
    # Phone-side create of the same sha converges on the same entry.
    body = client.post(
        "/ops/consent", json={"op": "write_file", "args_sha": rec["sha"]}, headers=_auth()
    ).json()
    assert body["consent_id"] == cid
    # Laptop approves → the orchestrator poll sees APPROVED immediately.
    assert client.post(f"/ops/consent/{cid}/approve", headers=_approval()).status_code == 200
    assert ops_poll_for_sha(mgr, rec["sha"], "write_file", timeout_seconds=0) is True


def test_ops_deny_visible_to_poll(app_ops) -> None:
    client = TestClient(app_ops)
    sha = "cd" * 32
    cid = client.post("/ops/consent", json={"op": "shell", "args_sha": sha}, headers=_auth()).json()[
        "consent_id"
    ]
    client.post(f"/ops/consent/{cid}/deny", headers=_approval())
    assert ops_poll_for_sha(app_ops.state.ops_consent, sha, "shell", timeout_seconds=5) is False


def test_command_passes_ops_consent_to_orchestrator(app_ops, monkeypatch) -> None:
    calls: list = []

    def _fake_run(text, task_id=None, source="text", ops_consent=None):
        calls.append({"text": text, "task_id": task_id, "source": source, "ops": ops_consent})
        return orch.TaskResult(ok=True, output="done", task_id=task_id or "x")

    monkeypatch.setattr(orch, "run", _fake_run)
    client = TestClient(app_ops)
    resp = client.post("/command", json={"text": "hi"}, headers=_auth())
    assert resp.status_code == 200
    assert calls and calls[0]["ops"] is app_ops.state.ops_consent


def test_load_ops_config_defaults_and_overrides(tmp_path) -> None:
    from server import streams
    from server.main import load_ops_config

    assert load_ops_config(tmp_path / "missing.yaml") == {
        "pending_ttl_seconds": 300.0,
        "grant_ttl_seconds": 600.0,
        "max_consent_records": 256,
    }
    custom = tmp_path / "sec.yaml"
    custom.write_text(
        yaml.safe_dump({"ops": {"pending_ttl_seconds": 60, "grant_ttl_seconds": 120}}),
        encoding="utf-8",
    )
    cfg = load_ops_config(custom)
    assert cfg["pending_ttl_seconds"] == 60.0
    assert cfg["grant_ttl_seconds"] == 120.0
    assert cfg["max_consent_records"] == 256  # default preserved
    garbage = tmp_path / "garbage.yaml"
    garbage.write_text(
        yaml.safe_dump({"ops": {"pending_ttl_seconds": -5, "grant_ttl_seconds": "x"}}),
        encoding="utf-8",
    )
    bad = load_ops_config(garbage)
    assert bad["pending_ttl_seconds"] == streams.OPS_PENDING_TTL_SECONDS
    assert bad["grant_ttl_seconds"] == streams.OPS_GRANT_TTL_SECONDS


def test_load_tools_config_memory_block() -> None:
    from buddy_core.config import MemoryConfig, load_tools_config

    cfg = load_tools_config()  # repo config/tools.yaml now ships the block
    assert isinstance(cfg.memory, MemoryConfig)
    assert cfg.memory.cap == 500
    assert cfg.memory.path == "logs/memory.jsonl"
