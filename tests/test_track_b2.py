"""Track B2 (CrewAI decision gate) tests — all fakes, no Ollama in pytest.

Covers: agents.framework parsing (default direct, fail-closed unknowns),
direct-by-default research (crew never called), crewai opt-in research
(crew summarizes, direct chat NOT used for the summary, same
validate_plan/redaction/event pipeline), llm-planner attribution intact
under crewai, crew failure fail-closed, long crew output truncated in the
log, the built crew's no-tools/no-delegation structure, and non-research
routes ignoring the flag.
"""

from __future__ import annotations

import json

import pytest

import buddy_core.config as cfg_module
import buddy_core.orchestrator as orch
from buddy_core.agents import crew as crew_module
from buddy_core.agents.crew import build_crew, summarize_with_crew
from buddy_core.agents.planner import Plan, PlanRejected, ToolCall
from buddy_core.config import ModelsConfig
from buddy_core.tools.web_search import SearchHit


# --- helpers ---


def _models_cfg(framework: str = "direct") -> ModelsConfig:
    return ModelsConfig(
        host="http://localhost:11434",
        dev_model="qwen2.5:3b",
        target_model="llama3.1:8b",
        fallback_model="qwen2.5:3b",
        voice_model="qwen2.5:3b",
        framework=framework,
    )


def _hits():
    return [SearchHit("T", "https://example.com/x", "S")]


def _patch_search(monkeypatch, marker: str = "body") -> None:
    monkeypatch.setattr(
        "buddy_core.tools.web_search.search",
        lambda q, cfg, max_results=5: _hits(),
    )
    monkeypatch.setattr(
        "buddy_core.tools.web_search.fetch_page_text",
        lambda url, max_chars=8000: marker,
    )


def _events(tmp_path) -> list:
    return [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]


class _FakeCrew:
    """Stand-in for a crewai Crew: kickoff() returns canned text, no network."""

    def __init__(self, text: str, seen: dict | None = None):
        self._text = text
        self.seen = seen if seen is not None else {}

    def kickoff(self):
        self.seen["kicked"] = True
        return self._text


class _FakeOllamaClient:
    """Injectable ollama-like client: list() for model-pick, chat() canned.

    chat() raises by default so crew-path tests prove the direct chat is
    truly untouched; direct-path tests pass a canned summary instead.
    """

    def __init__(self, summary: str | None = None):
        self._summary = summary
        self.chats = 0

    def list(self):
        return {"models": [{"name": "qwen2.5:3b"}]}

    def chat(self, model, messages, options=None):
        self.chats += 1
        if self._summary is None:
            raise AssertionError("direct client.chat must not run on the crew path")
        return {"message": {"content": self._summary}}


# --- 1. framework flag parsing ---


def test_framework_defaults_direct_in_repo_file() -> None:
    assert cfg_module.load_models_config().framework == "direct"


def test_framework_missing_section_is_direct(monkeypatch, tmp_path) -> None:
    import yaml

    (tmp_path / "models.yaml").write_text(
        yaml.safe_dump({"ollama": {"host": "http://localhost:11434"}}), encoding="utf-8"
    )
    monkeypatch.setattr(cfg_module, "CONFIG_DIR", tmp_path)
    assert cfg_module.load_models_config().framework == "direct"


@pytest.mark.parametrize("raw", ["crewai", "CrewAI", "  crewai  "])
def test_framework_crewai_opt_in_variants(monkeypatch, tmp_path, raw: str) -> None:
    import yaml

    (tmp_path / "models.yaml").write_text(
        yaml.safe_dump({"agents": {"framework": raw}}), encoding="utf-8"
    )
    monkeypatch.setattr(cfg_module, "CONFIG_DIR", tmp_path)
    assert cfg_module.load_models_config().framework == "crewai"


@pytest.mark.parametrize("raw", ["auto", "", "never", "crew", 123, None])
def test_framework_unknown_fails_closed_to_direct(monkeypatch, tmp_path, raw) -> None:
    import yaml

    (tmp_path / "models.yaml").write_text(
        yaml.safe_dump({"agents": {"framework": raw}}), encoding="utf-8"
    )
    monkeypatch.setattr(cfg_module, "CONFIG_DIR", tmp_path)
    assert cfg_module.load_models_config().framework == "direct"


def test_models_config_default_is_direct() -> None:
    assert ModelsConfig().framework == "direct"


# --- 2. direct by default: crew never touched ---


def test_research_direct_default_never_calls_crew(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orch, "load_models_config", lambda: _models_cfg("direct"))
    monkeypatch.setattr(
        orch, "build_llm_plan", lambda *a, **k: (_ for _ in ()).throw(PlanRejected("down"))
    )
    monkeypatch.setattr(
        crew_module, "summarize_with_crew", lambda *a, **k: (_ for _ in ()).throw(AssertionError("crew must not run"))
    )
    # Real direct summarizer end-to-end against the fake client.
    monkeypatch.setattr("ollama.Client", lambda *a, **k: _FakeOllamaClient("DIRECT SUMMARY"))
    _patch_search(monkeypatch)
    result = orch.run("research crew gate")
    assert result.ok
    assert result.output == "DIRECT SUMMARY"
    events = _events(tmp_path)
    assert [e["type"] for e in events] == ["task_started", "tool_call", "tool_call", "task_completed"]
    assert events[-1].get("planner") == "fallback"


# --- 3. crewai opt-in: crew summarizes, direct chat untouched ---


def test_research_crewai_uses_crew_not_direct_summarize(monkeypatch, tmp_path) -> None:
    marker = "B2_MARKER_REDACT_1a2b3c"
    seen: dict = {}
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orch, "load_models_config", lambda: _models_cfg("crewai"))
    monkeypatch.setattr(
        orch, "build_llm_plan", lambda *a, **k: (_ for _ in ()).throw(PlanRejected("down"))
    )

    def fake_crew_summarize(query, context, host, model):
        seen["query"] = query
        seen["context"] = context
        seen["model"] = model
        return "CREW SUMMARY ok"

    monkeypatch.setattr(crew_module, "summarize_with_crew", fake_crew_summarize)
    monkeypatch.setattr(orch, "_summarize_with_llm", lambda *a, **k: (_ for _ in ()).throw(AssertionError("direct must not summarize")))
    monkeypatch.setattr("ollama.Client", lambda *a, **k: _FakeOllamaClient())
    _patch_search(monkeypatch, marker)

    result = orch.run("research crew gate")
    assert result.ok
    assert result.output == "CREW SUMMARY ok"
    assert seen["query"] == "research crew gate"
    assert marker in seen["context"]  # crew got the page body as data...
    events = _events(tmp_path)
    assert [e["type"] for e in events] == ["task_started", "tool_call", "tool_call", "task_completed"]
    assert events[1]["tool"] == "web_search"
    assert events[1]["args"] == {"query": "research crew gate", "max_results": 5}
    assert events[2]["tool"] == "fetch_page"
    assert events[2]["args"] == {"url": "https://example.com/x"}
    assert events[3]["result"] == "CREW SUMMARY ok"
    assert events[3].get("planner") == "fallback"
    raw = (tmp_path / "events.jsonl").read_bytes()
    assert marker.encode() not in raw  # ...but it never reached the log


def test_crewai_keeps_llm_planner_attribution_and_planning_direct(monkeypatch, tmp_path) -> None:
    """Crew only replaces the SUMMARY call: planning still uses the direct
    client (exactly one chat = the planner), planner tag stays "llm"."""
    research_plan = Plan(
        steps=[
            ToolCall("web_search", {"query": "llm topic", "max_results": 2}),
            ToolCall("fetch_page", {"max_pages": 1, "max_chars": 500}),
        ],
        depth=0,
    )
    chats = {"n": 0}
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orch, "load_models_config", lambda: _models_cfg("crewai"))
    monkeypatch.setattr(orch, "build_llm_plan", lambda *a, **k: research_plan)
    monkeypatch.setattr("ollama.Client", lambda *a, **k: _FakeOllamaClient())
    monkeypatch.setattr(crew_module, "summarize_with_crew", lambda q, ctx, h, m: "CREW LLMSUMMARY")

    def _direct_must_not_summarize(*a, **k):
        chats["n"] += 1
        raise AssertionError("direct summarize must not run under crewai")

    monkeypatch.setattr(orch, "_summarize_with_llm", _direct_must_not_summarize)
    _patch_search(monkeypatch)

    result = orch.run("tell me about llm topic")
    assert result.ok
    assert result.output == "CREW LLMSUMMARY"
    assert chats["n"] == 0
    events = _events(tmp_path)
    assert events[-1]["type"] == "task_completed"
    assert events[-1].get("planner") == "llm"


def test_crew_failure_fails_closed(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orch, "load_models_config", lambda: _models_cfg("crewai"))
    monkeypatch.setattr(
        orch, "build_llm_plan", lambda *a, **k: (_ for _ in ()).throw(PlanRejected("down"))
    )

    def _boom(query, context, host, model):
        raise RuntimeError("crew exploded")

    monkeypatch.setattr(crew_module, "summarize_with_crew", _boom)
    monkeypatch.setattr("ollama.Client", lambda *a, **k: _FakeOllamaClient())
    _patch_search(monkeypatch)

    result = orch.run("research boom")
    assert not result.ok
    assert "RuntimeError" in result.output
    events = _events(tmp_path)
    assert events[-1]["type"] == "task_failed"
    assert events[-1].get("planner") == "fallback"


def test_crew_long_output_truncated_in_log_not_caller(monkeypatch, tmp_path) -> None:
    """Parity with direct: the caller gets the full text, the log only
    ever sees output[:2000] — no raw crew text lands untruncated."""
    long_text = "C" * 5000
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orch, "load_models_config", lambda: _models_cfg("crewai"))
    monkeypatch.setattr(
        orch, "build_llm_plan", lambda *a, **k: (_ for _ in ()).throw(PlanRejected("down"))
    )
    monkeypatch.setattr(crew_module, "summarize_with_crew", lambda q, ctx, h, m: long_text)
    monkeypatch.setattr("ollama.Client", lambda *a, **k: _FakeOllamaClient())
    _patch_search(monkeypatch)

    result = orch.run("research long")
    assert result.ok
    assert result.output == long_text  # caller parity with direct
    events = _events(tmp_path)
    assert events[-1]["result"] == long_text[:2000]
    assert len(events[-1]["result"]) == 2000


# --- 4. crew module unit tests (fake factory, no Ollama) ---


def test_summarize_with_crew_uses_factory_and_strips() -> None:
    seen: dict = {}
    crew = _FakeCrew("  hello summary  ", seen)

    def factory(query, context, host, model):
        seen["args"] = (query, context, host, model)
        return crew

    out = summarize_with_crew("q?", "ctx", "http://h", "m", crew_factory=factory)
    assert out == "hello summary"
    assert seen["args"] == ("q?", "ctx", "http://h", "m")
    assert seen["kicked"] is True


def test_summarize_with_crew_empty_raises() -> None:
    with pytest.raises(ValueError, match="[Ee]mpty"):
        summarize_with_crew("q", "ctx", "http://h", "m", crew_factory=lambda *a: _FakeCrew("   \n  "))


def test_built_crew_has_no_tools_no_delegation() -> None:
    """Structural pin: the thing we timed in the spike is the thing we
    wire — bounded agents, zero tools anywhere, sequential, one task."""
    from crewai import Process

    crew = build_crew("q", "ctx", "http://localhost:11434", "qwen2.5:3b")
    assert len(crew.agents) == 2
    assert sorted(a.role for a in crew.agents) == ["Planner", "Researcher"]
    for agent in crew.agents:
        assert list(getattr(agent, "tools", None) or []) == []
        assert agent.allow_delegation is False
        assert agent.max_iter == 2
    assert len(crew.tasks) == 1
    assert getattr(crew.tasks[0], "tools", None) in (None, [])
    assert crew.process == Process.sequential
    models = {getattr(a.llm, "model", "") for a in crew.agents}
    # crewai normalizes "ollama/<tag>" to "<tag>" on the LLM object — pin
    # that both agents share exactly the model we passed.
    assert models == {"qwen2.5:3b"}


# --- 5. non-research routes ignore the flag ---


def test_launch_route_ignores_crewai_flag(monkeypatch, tmp_path) -> None:
    """framework==crewai must not touch launch: crew raising would fail
    the test if the route were (wrongly) crew-backed."""
    from buddy_core.config import AppEntry, AppsConfig
    from buddy_core.tools.launch_app import LaunchResult

    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(orch, "load_models_config", lambda: _models_cfg("crewai"))
    monkeypatch.setattr(
        orch, "build_llm_plan", lambda *a, **k: (_ for _ in ()).throw(PlanRejected("down"))
    )
    monkeypatch.setattr(
        "buddy_core.orchestrator.load_apps_config",
        lambda: AppsConfig(apps={"notepad": AppEntry(display="Notepad", launcher=r"C:\windows\system32\notepad.exe")}),
    )
    monkeypatch.setattr(
        "buddy_core.tools.launch_app.launch",
        lambda key, cfg, tools: LaunchResult(ok=True, message="Started PID 42", pid=42),
    )
    monkeypatch.setattr(
        crew_module, "summarize_with_crew", lambda *a, **k: (_ for _ in ()).throw(AssertionError("crew must not run"))
    )
    result = orch.run("open notepad")
    assert result.ok
    assert "Launched Notepad" in result.output
    events = _events(tmp_path)
    assert events[-1]["type"] == "task_completed"
    assert events[-1].get("planner") == "fallback"
