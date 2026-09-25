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

from buddy_core.agents.planner import (
    LAUNCH_VERBS,
    build_code_plan,
    build_list_apps_plan,
    build_research_plan,
    validate_plan,
    resolve_launch_intent,
)
from buddy_core.agents.coder import resolve_code_target as coder_resolve_target
from buddy_core.agents.executor import redact_event_args
from buddy_core.config import load_apps_config, load_models_config, load_tools_config

REPO_ROOT = Path(__file__).resolve().parent.parent
EVENT_LOG = REPO_ROOT / "logs" / "events.jsonl"

# Explicit client timeout (Track A1): no unbounded Ollama call from /command.
OLLAMA_TIMEOUT_SECONDS = 60

# Bounded log (Track A2): rotate events.jsonl at 5MB, keep 1 ".1" backup.
# Monkeypatchable in tests (small threshold forces rotation without 5MB I/O).
EVENT_LOG_MAX_BYTES = 5 * 1024 * 1024


@dataclass
class TaskResult:
    ok: bool
    output: str
    task_id: str = ""
    steps_taken: int = 0


def _log_event(event_type: str, payload: dict) -> None:
    """Append one agent-lifecycle event (API.md shapes) to logs/events.jsonl.

    Track A2 — bounded log: if the file is at/over EVENT_LOG_MAX_BYTES,
    rotate it to ``events.jsonl.1`` (single backup, overwrite) before
    appending, so the log never grows unbounded. Tool-call args are
    assumed already redacted by the caller via
    ``executor.redact_event_args`` — this function never expands them.
    """
    EVENT_LOG.parent.mkdir(parents=True, exist_ok=True)
    try:
        if EVENT_LOG.exists() and EVENT_LOG.stat().st_size >= EVENT_LOG_MAX_BYTES:
            backup = EVENT_LOG.with_name(EVENT_LOG.name + ".1")
            try:
                EVENT_LOG.replace(backup)
            except OSError:
                pass
    except OSError:
        pass
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


def _pick_model(client: object, models, source: str = "text") -> str:
    """Deliberate latency-vs-quality routing (not error fallback).

    - source="voice" (voice_loop): prefer voice_model first — round-trip
      latency is the UX, so the fast model wins when pulled.
    - source="text" (default, POST /command): prefer target_model first —
      the user is already reading/waiting, so quality wins.

    Unpulled candidates fall through; never fail on a missing tag.
    """
    voice_model = getattr(models, "voice_model", models.dev_model)
    if source == "voice":
        candidates = (voice_model, models.dev_model, models.fallback_model, models.target_model)
    else:
        candidates = (models.target_model, models.dev_model, models.fallback_model, voice_model)
    names = _model_names(client)
    if not names:
        return voice_model if source == "voice" else models.fallback_model
    bases = {n.split(":")[0] for n in names}
    for candidate in candidates:
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


def _run_launch(
    task_id: str,
    app_key: str,
    apps_cfg,
    tools_cfg,
    limits,
) -> TaskResult:
    """Execute a launch_app plan: resolve key -> validate -> fire-and-forget."""
    from buddy_core.tools import launch_app

    _log_event(
        "tool_call",
        {"task_id": task_id, "tool": "launch_app", "args": redact_event_args("launch_app", {"app_key": app_key})},
    )
    try:
        result = launch_app.launch(app_key, apps_cfg, tools_cfg)
    except launch_app.AppNotFound as exc:
        _log_event("task_failed", {"task_id": task_id, "error": str(exc)})
        return TaskResult(ok=False, output=str(exc), task_id=task_id, steps_taken=1)
    if not result.ok:
        _log_event("task_failed", {"task_id": task_id, "error": result.message})
        return TaskResult(ok=False, output=result.message, task_id=task_id, steps_taken=1)
    _log_event("task_completed", {"task_id": task_id, "result": result.message})
    entry = apps_cfg.apps[app_key]
    return TaskResult(ok=True, output=f"Launched {entry.display}.", task_id=task_id, steps_taken=1)


def _is_list_apps(command: str) -> bool:
    return command.lower().strip() in (
        "list apps",
        "show apps",
        "what apps",
        "apps you can open",
        "list applications",
    )


def _is_launch_verb(command: str) -> bool:
    text = command.lower().strip().split()[0] if command.strip() else ""
    return any(text == v for v in LAUNCH_VERBS)


def _run_list_apps(task_id: str, apps_cfg, tools_cfg, limits) -> TaskResult:
    from buddy_core.tools import launch_app

    _log_event("tool_call", {"task_id": task_id, "tool": "list_apps", "args": redact_event_args("list_apps", {})})
    entries = launch_app.list_apps(apps_cfg)
    out = "\n".join(entries) if entries else "No apps are registered in config/apps.yaml."
    _log_event("task_completed", {"task_id": task_id, "result": out[:2000]})
    return TaskResult(ok=True, output=out, task_id=task_id, steps_taken=1)


def _run_code(task_id: str, command: str, rel_path: str, models, tools_cfg, source: str) -> TaskResult:
    """Coder flow: LLM drafts content → validated write_file plan → executor runs it."""
    import ollama

    from buddy_core.agents import coder
    from buddy_core.agents.executor import execute_plan

    try:
        client = ollama.Client(host=models.host, timeout=OLLAMA_TIMEOUT_SECONDS)
        model = _pick_model(client, models, source=source)
        content = coder.draft_content(client, model, command, rel_path)
        plan = build_code_plan(rel_path, content, tools_cfg.agent_limits)
    except Exception as exc:
        err = f"{type(exc).__name__}: {exc}"
        _log_event("task_failed", {"task_id": task_id, "error": err})
        return TaskResult(ok=False, output=err, task_id=task_id)
    result = execute_plan(plan, tools_cfg, task_id, _log_event)
    if result.ok:
        _log_event("task_completed", {"task_id": task_id, "result": result.output[:2000]})
        return TaskResult(ok=True, output=f"Saved {rel_path} in the workspace.", task_id=task_id, steps_taken=result.steps_taken + 1)
    _log_event("task_failed", {"task_id": task_id, "error": result.output})
    return TaskResult(ok=False, output=result.output, task_id=task_id, steps_taken=result.steps_taken)


def run(command: str, task_id: str | None = None, source: str = "text") -> TaskResult:
    """Execute a command end-to-end. Never raises on agent failure — returns TaskResult.

    source: "text" (default, POST /command — quality-first) or "voice"
    (voice_loop — latency-first, prefers voice_model). See _pick_model.

    Track A2 — no silent task loss: task_started + config loads live INSIDE
    the try block, so a corrupt config or a failed log write still emits
    task_failed instead of raising. Empty commands emit task_failed (with
    the text echoed truncated) instead of returning silently.
    """
    task_id = task_id or uuid.uuid4().hex[:12]
    try:
        command = command.strip() if isinstance(command, str) else ""
    except Exception:
        command = ""
    if not command:
        try:
            _log_event(
                "task_failed",
                {"task_id": task_id, "error": "Empty command.", "text": command[:200]},
            )
        except Exception:
            pass
        return TaskResult(ok=False, output="Empty command.", task_id=task_id)
    try:
        _log_event("task_started", {"task_id": task_id, "text": command, "source": source})

        models = load_models_config()
        tools_cfg = load_tools_config()
        apps_cfg = load_apps_config()
        limits = tools_cfg.agent_limits

        app_key = resolve_launch_intent(command, apps_cfg)
        if app_key:
            return _run_launch(task_id, app_key, apps_cfg, tools_cfg, limits)
        if _is_launch_verb(command):
            known = ", ".join(sorted(apps_cfg.apps)) or "(none registered)"
            _log_event("task_failed", {"task_id": task_id, "error": "Unknown app"})
            return TaskResult(
                ok=False,
                output=f"Unknown app. Registered: {known}. Say 'list apps' for a full list.",
                task_id=task_id,
            )
        if _is_list_apps(command):
            return _run_list_apps(task_id, apps_cfg, tools_cfg, limits)
        code_target = coder_resolve_target(command)
        if code_target:
            return _run_code(task_id, command, code_target, models, tools_cfg, source)
        plan = build_research_plan(command, limits)
        validate_plan(plan, limits)
    except Exception as exc:
        try:
            _log_event("task_failed", {"task_id": task_id, "error": str(exc)})
        except Exception:
            pass
        return TaskResult(ok=False, output=f"Plan rejected: {exc}", task_id=task_id)

    steps_taken = 0
    try:
        import ollama

        from buddy_core.tools import web_search

        client = ollama.Client(host=models.host, timeout=OLLAMA_TIMEOUT_SECONDS)
        model = _pick_model(client, models, source=source)

        # Step 1 — typed web_search call (no raw LLM text involved).
        step = plan.steps[0]
        _log_event(
            "tool_call",
            {"task_id": task_id, "tool": "web_search", "args": redact_event_args("web_search", step.args)},
        )
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
            _log_event(
                "tool_call",
                {"task_id": task_id, "tool": "fetch_page", "args": redact_event_args("fetch_page", {"url": hit.url})},
            )
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
