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


def test_run_handles_ollama_down(monkeypatch, tmp_path) -> None:
    class _Down:
        def __init__(self, *args, **kwargs):
            raise ConnectionError("refused")

    monkeypatch.setattr("ollama.Client", _Down)
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    result = orch.run("hello")
    assert not result.ok
    assert "Ollama" in result.output
