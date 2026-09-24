"""Tests for buddy_core/orchestrator.py — Ollama + network stubbed out."""

import json

import buddy_core.orchestrator as orch
from buddy_core.tools.web_search import SearchHit


class _FakeClient:
    def __init__(self, *args, **kwargs):
        pass

    def list(self):
        return {"models": [{"name": "qwen2.5:3b"}]}

    def chat(self, model, messages, options=None):
        return {"message": {"content": "SUMMARY: local LLMs run offline."}}


def test_run_happy_path(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr("ollama.Client", _FakeClient)
    monkeypatch.setattr(
        "buddy_core.tools.web_search.search",
        lambda q, cfg, max_results=5: [SearchHit("T", "https://example.com", "S")],
    )
    monkeypatch.setattr(
        "buddy_core.tools.web_search.fetch_page_text",
        lambda url, max_chars=8000: "page body",
    )
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")

    result = orch.run("research local LLMs")
    assert result.ok
    assert "SUMMARY" in result.output
    assert result.steps_taken >= 3

    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    types = [e["type"] for e in events]
    assert types[0] == "task_started"
    assert "tool_call" in types
    assert types[-1] == "task_completed"


def test_run_empty_command() -> None:
    result = orch.run("   ")
    assert not result.ok


class _TwoModelClient:
    """Both voice (fast) and target (quality) models pulled."""

    def __init__(self, *args, **kwargs):
        pass

    def list(self):
        return {"models": [{"name": "qwen2.5:3b"}, {"name": "llama3.1:8b"}]}

    def chat(self, model, messages, options=None):
        return {"message": {"content": f"MODEL:{model}"}}


def _route_setup(monkeypatch, tmp_path):
    from buddy_core.config import ModelsConfig

    monkeypatch.setattr("ollama.Client", _TwoModelClient)
    monkeypatch.setattr(
        "buddy_core.tools.web_search.search",
        lambda q, cfg, max_results=5: [SearchHit("T", "https://example.com", "S")],
    )
    monkeypatch.setattr(
        "buddy_core.tools.web_search.fetch_page_text",
        lambda url, max_chars=8000: "page body",
    )
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(
        "buddy_core.orchestrator.load_models_config",
        lambda: ModelsConfig(
            host="http://localhost:11434",
            dev_model="qwen2.5:3b",
            target_model="llama3.1:8b",
            fallback_model="qwen2.5:3b",
            voice_model="qwen2.5:3b",
        ),
    )


def test_voice_source_prefers_fast_model(monkeypatch, tmp_path) -> None:
    _route_setup(monkeypatch, tmp_path)
    result = orch.run("hello", source="voice")
    assert result.ok
    assert "MODEL:qwen2.5:3b" in result.output


def test_text_source_prefers_quality_model(monkeypatch, tmp_path) -> None:
    _route_setup(monkeypatch, tmp_path)
    result = orch.run("hello")
    assert result.ok
    assert "MODEL:llama3.1:8b" in result.output


def test_voice_falls_through_when_fast_missing(monkeypatch, tmp_path) -> None:
    """Only the quality model pulled — voice must still work (fallthrough)."""

    class _OnlyTarget:
        def __init__(self, *args, **kwargs):
            pass

        def list(self):
            return {"models": [{"name": "llama3.1:8b"}]}

        def chat(self, model, messages, options=None):
            return {"message": {"content": f"MODEL:{model}"}}

    from buddy_core.config import ModelsConfig

    monkeypatch.setattr("ollama.Client", _OnlyTarget)
    monkeypatch.setattr(
        "buddy_core.tools.web_search.search",
        lambda q, cfg, max_results=5: [SearchHit("T", "https://example.com", "S")],
    )
    monkeypatch.setattr(
        "buddy_core.tools.web_search.fetch_page_text",
        lambda url, max_chars=8000: "page body",
    )
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(
        "buddy_core.orchestrator.load_models_config",
        lambda: ModelsConfig(
            host="http://localhost:11434",
            dev_model="qwen2.5:3b",
            target_model="llama3.1:8b",
            fallback_model="qwen2.5:3b",
            voice_model="qwen2.5:3b",
        ),
    )
    result = orch.run("hello", source="voice")
    assert result.ok
    assert "MODEL:llama3.1:8b" in result.output


def test_run_handles_ollama_down(monkeypatch, tmp_path) -> None:
    class _Down:
        def __init__(self, *args, **kwargs):
            raise ConnectionError("refused")

    monkeypatch.setattr("ollama.Client", _Down)
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    result = orch.run("hello")
    assert not result.ok
    assert "Ollama" in result.output


def _fake_apps_config():
    from buddy_core.config import AppEntry, AppsConfig

    return AppsConfig(
        apps={
            "notepad": AppEntry(display="Notepad", launcher=r"C:\windows\system32\notepad.exe"),
        }
    )


def test_run_launch_app_happy_path(monkeypatch, tmp_path) -> None:
    from buddy_core.tools import launch_app
    from buddy_core.tools.launch_app import LaunchResult

    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(
        "buddy_core.orchestrator.load_apps_config",
        lambda: _fake_apps_config(),
    )
    monkeypatch.setattr(
        "buddy_core.tools.launch_app.launch",
        lambda key, cfg, tools: LaunchResult(ok=True, message="Started PID 42", pid=42),
    )
    result = orch.run("open notepad")
    assert result.ok
    assert "Launched Notepad" in result.output
    assert result.steps_taken == 1

    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    types = [e["type"] for e in events]
    assert types[0] == "task_started"
    assert "tool_call" in types
    assert events[-1]["type"] == "task_completed"
    assert events[-2]["tool"] == "launch_app"


def test_run_launch_unknown_app_fails_closed(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(
        "buddy_core.orchestrator.load_apps_config",
        lambda: _fake_apps_config(),
    )
    result = orch.run("open spotify")
    assert not result.ok
    assert "Unknown app" in result.output

    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert events[-1]["type"] == "task_failed"


def test_run_list_apps(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr(
        "buddy_core.orchestrator.load_apps_config",
        lambda: _fake_apps_config(),
    )
    result = orch.run("list apps")
    assert result.ok
    assert "notepad" in result.output
    assert result.steps_taken == 1
