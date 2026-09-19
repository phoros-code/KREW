"""Orchestrator — owns the agent crew and the single public entrypoint.

``run(command: str) -> TaskResult`` is the ONLY way to execute work:
``voice_loop.py`` and ``server/main.py`` both call this, never agents
directly (ARCHITECTURE.md).

Phase 0: a single ResearchAgent flow (search → fetch → summarize) backed by
Ollama, driven by the typed plan from ``agents/planner.py``. CrewAI wiring
lands once the Python 3.12 environment is ready (crewai's pinned langchain
requires numpy<2, which has no Python 3.14 wheel) — the typed-plan boundary
here is exactly what CrewAI tasks will consume, so nothing above this file
changes when that swap happens.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from buddy_core.agents.planner import build_research_plan, validate_plan
from buddy_core.config import load_models_config, load_tools_config

REPO_ROOT = Path(__file__).resolve().parent.parent
EVENT_LOG = REPO_ROOT / "logs" / "events.jsonl"


@dataclass
class TaskResult:
    ok: bool
    output: str
    task_id: str = ""
    steps_taken: int = 0


def _log_event(event_type: str, payload: dict) -> None:
    """Append one agent-lifecycle event (API.md shapes) to logs/events.jsonl."""
    EVENT_LOG.parent.mkdir(parents=True, exist_ok=True)
    record = {"type": event_type, "at": datetime.now(timezone.utc).isoformat(), **payload}
    with EVENT_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")


def _model_names(client: object) -> list[str]:
    """Extract pulled model names, handling dict- and object-style list responses."""
    try:
        data = client.list()
    except Exception:
        return []
    if isinstance(data, dict):
        models = data.get("models", [])
    else:
        models = getattr(data, "models", []) or []
    names: list[str] = []
    for m in models:
        if isinstance(m, dict):
            name = m.get("name", "") or m.get("model", "")
        else:
            name = getattr(m, "model", "") or ""
        if name:
            names.append(name)
    return names


def _pick_model(client: object, models) -> str:
    """Use target_model if pulled, else fallback/dev — never fail on a missing tag."""
    names = _model_names(client)
    if not names:
        return models.fallback_model
    bases = {n.split(":")[0] for n in names}
    for candidate in (models.target_model, models.dev_model, models.fallback_model):
        if candidate in names or candidate.split(":")[0] in bases:
            return candidate
    # Nothing configured is pulled (e.g. only qwen2.5-coder present) — use what's there.
    return names[0]


def _summarize_with_llm(client: object, model: str, command: str, context: str) -> str:
    resp = client.chat(
        model=model,
        messages=[
            {
                "role": "system",
                "content": (
                    "You are Everyday Buddy, a local-first research assistant. "
                    "Answer ONLY from the provided search context. Be concise: "
                    "a short summary plus a bullet list of key points with source URLs."
                ),
            },
            {"role": "user", "content": f"Task: {command}\n\nSearch context:\n{context}"},
        ],
        options={"temperature": 0.2},
    )
    return resp["message"]["content"].strip()


def run(command: str, task_id: str | None = None) -> TaskResult:
    """Execute a command end-to-end. Never raises on agent failure — returns TaskResult."""
    task_id = task_id or uuid.uuid4().hex[:12]
    command = command.strip()
    if not command:
        return TaskResult(ok=False, output="Empty command.", task_id=task_id)
    _log_event("task_started", {"task_id": task_id, "text": command})

    models = load_models_config()
    tools_cfg = load_tools_config()
    limits = tools_cfg.agent_limits

    try:
        plan = build_research_plan(command, limits)
        validate_plan(plan, limits)
    except Exception as exc:
        _log_event("task_failed", {"task_id": task_id, "error": str(exc)})
        return TaskResult(ok=False, output=f"Plan rejected: {exc}", task_id=task_id)

    steps_taken = 0
    try:
        import ollama

        from buddy_core.tools import web_search

        client = ollama.Client(host=models.host)
        model = _pick_model(client, models)

        # Step 1 — typed web_search call (no raw LLM text involved).
        step = plan.steps[0]
        _log_event("tool_call", {"task_id": task_id, "tool": "web_search", "args": step.args})
        hits = web_search.search(step.args["query"], tools_cfg.web_search, max_results=step.args.get("max_results", 5))
        steps_taken += 1
        if not hits:
            out = "No search results found."
            _log_event("task_completed", {"task_id": task_id, "result": out})
            return TaskResult(ok=True, output=out, task_id=task_id, steps_taken=steps_taken)

        # Step 2 — fetch top pages as inert data.
        fetch_args = plan.steps[1].args
        context_parts: list[str] = []
        for hit in hits[: int(fetch_args.get("max_pages", 2))]:
            _log_event("tool_call", {"task_id": task_id, "tool": "fetch_page", "args": {"url": hit.url}})
            try:
                body = web_search.fetch_page_text(hit.url, max_chars=int(fetch_args.get("max_chars", 8000)))
            except Exception as exc:
                body = f"(fetch failed: {exc})"
            context_parts.append(f"SOURCE: {hit.title} — {hit.url}\n{hit.snippet}\n{body}")
            steps_taken += 1

        # Step 3 — local summarization.
        output = _summarize_with_llm(client, model, command, "\n\n---\n\n".join(context_parts))
        steps_taken += 1
        _log_event("task_completed", {"task_id": task_id, "result": output[:2000]})
        return TaskResult(ok=True, output=output, task_id=task_id, steps_taken=steps_taken)
    except Exception as exc:
        err = f"{type(exc).__name__}: {exc}"
        if "ConnectError" in type(exc).__name__ or "Connection" in err:
            err = f"Cannot reach Ollama at {models.host}. Is `ollama serve` running? ({exc})"
        _log_event("task_failed", {"task_id": task_id, "error": err})
        return TaskResult(ok=False, output=err, task_id=task_id, steps_taken=steps_taken)
