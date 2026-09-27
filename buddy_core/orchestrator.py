"""Orchestrator — owns the agent crew and the single public entrypoint.

``run(command: str) -> TaskResult`` is the ONLY way to execute work:
``voice_loop.py`` and ``server/main.py`` both call this, never agents
directly (ARCHITECTURE.md).

Track B1: the LLM planner (``planner.build_llm_plan``) is primary for
free-form commands; the deterministic builders (launch/list/code/research)
are the fail-closed fallback. Research execution lives in
``agents/researcher.py`` (``run_research``) — this file only owns routing,
event emission (with ``planner``: "llm"|"fallback" on completion events),
and model routing.

Track B2 (CrewAI decision gate, wired 2026-09-27): when
``agents.framework == "crewai"`` in config/models.yaml AND the command
routes to research, the research SUMMARY step runs through a bounded
CrewAI crew (``agents/crew.py`` — planner+researcher, no tools); planning,
validation, redaction, and events are unchanged. Every other route
(launch/list/code/executor) and the default (framework=direct) stay on
direct Ollama calls — the typed-plan boundary here is unchanged, so
nothing above this file changes either way.

Track B3: LLM plans of pure shell/read/list/write steps EXECUTE via
``execute_plan`` (destructive steps pause for laptop consent through the
ops queue); genuinely mixed/unknown shapes still fall back to the
deterministic builders. The orchestrator remembers redacted task
summaries (``buddy_core/memory``) and injects the last few into the LLM
planner prompt as bounded DATA context. ``planner`` attribution
("llm"|"fallback") is preserved on all completion events.
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
    build_launch_plan,
    build_list_apps_plan,
    build_llm_plan,
    build_research_plan,
    validate_plan,
    resolve_launch_intent,
)
from buddy_core.agents.coder import resolve_code_target as coder_resolve_target
from buddy_core.agents.executor import EXECUTOR_TOOLS, redact_event_args
from buddy_core.config import load_apps_config, load_models_config, load_tools_config
from buddy_core.memory.memory import MEMORY_RECALL_DEFAULT

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


def _load_memory_store_safe():
    """Load the B3 memory store. Returns None (memory off) on any failure."""
    try:
        from buddy_core.memory.memory import MemoryStore

        tools_cfg = load_tools_config()
        mem = getattr(tools_cfg, "memory", None)
        path = getattr(mem, "path", None)
        cap = getattr(mem, "cap", None)
        return MemoryStore(path=path, cap=cap)
    except Exception:
        return None


def _recall_memories_safe(store, limit: int = MEMORY_RECALL_DEFAULT) -> list:
    """Recall the last ``limit`` memories. Never raises — [] on any failure."""
    if store is None:
        return []
    try:
        memories = store.recall(limit=limit)
    except Exception:
        return []
    return [m for m in memories if isinstance(m, dict)]


def _remember_safe(store, kind: str, text: str) -> None:
    """Remember one redacted summary. Never raises — memory must not break run()."""
    if store is None:
        return
    try:
        store.remember(kind, text)
    except Exception:
        pass


def _make_consent_checker(ops_consent):
    """Build the executor approval callback from server context (Track B3).

    ``ops_consent`` is the server's ops ConsentManager (or a duck-typed
    fake in tests). None → no approvals exist → destructive steps pause
    fail-closed. The checker polls the sha-indexed queue with a bounded
    wait, then returns False (fail closed on deny/timeout/error).
    """
    if ops_consent is None:
        return None

    def _check(record: dict) -> bool:
        try:
            from buddy_core.agents import executor as _exec

            return bool(
                _exec.ops_poll_for_sha(
                    ops_consent, record.get("sha", ""), record.get("tool", "")
                )
            )
        except Exception:
            return False

    return _check


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
    planner: str = "fallback",
) -> TaskResult:
    """Execute a launch_app plan: build -> validate -> execute the single step.

    Track A4: the typed plan (planner.build_launch_plan) is the only thing
    that reaches the tool — an oversized plan or unknown tool is rejected by
    validate_plan (raising PlanRejected to run()'s handler) before anything
    launches. Emitted event shapes are unchanged: tool_call(launch_app)
    then task_completed/task_failed, same payloads as before (plus
    Track B1 ``planner`` on the completion events).
    """
    from buddy_core.tools import launch_app

    plan = build_launch_plan(app_key, limits)
    validate_plan(plan, limits)
    step_args = plan.steps[0].args
    _log_event(
        "tool_call",
        {"task_id": task_id, "tool": "launch_app", "args": redact_event_args("launch_app", step_args)},
    )
    try:
        result = launch_app.launch(step_args["app_key"], apps_cfg, tools_cfg)
    except launch_app.AppNotFound as exc:
        _log_event("task_failed", {"task_id": task_id, "error": str(exc), "planner": planner})
        return TaskResult(ok=False, output=str(exc), task_id=task_id, steps_taken=1)
    if not result.ok:
        _log_event("task_failed", {"task_id": task_id, "error": result.message, "planner": planner})
        return TaskResult(ok=False, output=result.message, task_id=task_id, steps_taken=1)
    _log_event("task_completed", {"task_id": task_id, "result": result.message, "planner": planner})
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


def _run_list_apps(task_id: str, apps_cfg, tools_cfg, limits, planner: str = "fallback") -> TaskResult:
    """Execute a list_apps plan: build -> validate -> execute the single step.

    Track A4: same typed-plan discipline as _run_launch — the validated plan
    is the only thing that reaches the tool. Event shapes unchanged (plus
    Track B1 ``planner`` on the completion event).
    """
    from buddy_core.tools import launch_app

    plan = build_list_apps_plan(limits)
    validate_plan(plan, limits)
    _log_event("tool_call", {"task_id": task_id, "tool": "list_apps", "args": redact_event_args("list_apps", plan.steps[0].args)})
    entries = launch_app.list_apps(apps_cfg)
    out = "\n".join(entries) if entries else "No apps are registered in config/apps.yaml."
    _log_event("task_completed", {"task_id": task_id, "result": out[:2000], "planner": planner})
    return TaskResult(ok=True, output=out, task_id=task_id, steps_taken=1)


def _run_code(
    task_id: str,
    command: str,
    rel_path: str,
    models,
    tools_cfg,
    source: str,
    planner: str = "fallback",
    ops_consent=None,
) -> TaskResult:
    """Coder flow: LLM drafts content → validated write_file plan → executor runs it.

    Track B3: the executor runs with the run's consent checker, so
    regenerating an existing file pauses for laptop consent instead of
    silently overwriting.
    """
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
        _log_event("task_failed", {"task_id": task_id, "error": err, "planner": planner})
        return TaskResult(ok=False, output=err, task_id=task_id)
    result = execute_plan(plan, tools_cfg, task_id, _log_event, _make_consent_checker(ops_consent))
    if result.ok:
        _log_event("task_completed", {"task_id": task_id, "result": result.output[:2000], "planner": planner})
        return TaskResult(ok=True, output=f"Saved {rel_path} in the workspace.", task_id=task_id, steps_taken=result.steps_taken + 1)
    _log_event("task_failed", {"task_id": task_id, "error": result.output, "planner": planner})
    return TaskResult(ok=False, output=result.output, task_id=task_id, steps_taken=result.steps_taken)


def _ollama_unreachable_message(models, exc: Exception) -> str:
    err = f"{type(exc).__name__}: {exc}"
    if "ConnectError" in type(exc).__name__ or "Connection" in err:
        return f"Cannot reach Ollama at {models.host}. Is `ollama serve` running? ({exc})"
    return err


def _run_research(
    task_id: str,
    command: str,
    models,
    tools_cfg,
    max_results: int,
    max_pages: int,
    max_chars: int,
    source: str,
    planner: str,
) -> TaskResult:
    """Research flow via ResearchAgent (Track B1).

    Delegates search/fetch/summarize to ``researcher.run_research`` with
    injectable wrappers that emit the SAME redacted ``tool_call`` events
    as the old inlined flow (web_search with query+max_results, fetch_page
    with url). Completion events carry ``planner`` ("llm"|"fallback").

    Track B2: when ``models.framework == "crewai"``, the summarize step
    runs through ``agents/crew.py`` (bounded planner+researcher crew, no
    tools) using the SAME picked model; search/fetch/validation/events
    are unchanged. Any crew error fail-closes to task_failed below.
    """
    import ollama

    from buddy_core.agents import researcher
    from buddy_core.tools import web_search

    steps_taken = 0
    try:
        client = ollama.Client(host=models.host, timeout=OLLAMA_TIMEOUT_SECONDS)
        model = _pick_model(client, models, source=source)

        def search_fn(query: str, limit: int):
            nonlocal steps_taken
            _log_event(
                "tool_call",
                {
                    "task_id": task_id,
                    "tool": "web_search",
                    "args": redact_event_args("web_search", {"query": query, "max_results": limit}),
                },
            )
            hits = web_search.search(query, tools_cfg.web_search, max_results=limit)
            steps_taken += 1
            return hits

        def fetch_fn(url: str, limit: int):
            nonlocal steps_taken
            _log_event(
                "tool_call",
                {"task_id": task_id, "tool": "fetch_page", "args": redact_event_args("fetch_page", {"url": url})},
            )
            try:
                body = web_search.fetch_page_text(url, max_chars=int(limit))
            except Exception as exc:
                body = f"(fetch failed: {exc})"
            steps_taken += 1
            return body

        def llm_summarize(query: str, context: str):
            nonlocal steps_taken
            # Track B2: crew summarizes ONLY on the research route with the
            # framework opt-in. Planning above, validate_plan below,
            # redacted tool_call events, and truncated task_completed are
            # identical on both branches — the crew's text never reaches a
            # tool, and the log only ever sees output[:2000].
            if getattr(models, "framework", "direct") == "crewai":
                from buddy_core.agents import crew as crew_agent

                out = crew_agent.summarize_with_crew(query, context, models.host, model)
            else:
                out = _summarize_with_llm(client, model, query, context)
            steps_taken += 1
            return out

        limits = {"max_results": max_results, "max_pages": max_pages, "max_chars": max_chars}
        output = researcher.run_research(command, limits, search_fn, fetch_fn, llm_summarize)
        _log_event("task_completed", {"task_id": task_id, "result": output[:2000], "planner": planner})
        return TaskResult(ok=True, output=output, task_id=task_id, steps_taken=steps_taken)
    except Exception as exc:
        err = _ollama_unreachable_message(models, exc)
        _log_event("task_failed", {"task_id": task_id, "error": err, "planner": planner})
        return TaskResult(ok=False, output=err, task_id=task_id, steps_taken=steps_taken)


def _research_limits_from_plan(plan) -> tuple[int, int, int]:
    """Extract (max_results, max_pages, max_chars) from a research plan."""
    max_results, max_pages, max_chars = 5, 2, 8000
    try:
        for step in plan.steps:
            if step.tool == "web_search":
                max_results = int(step.args.get("max_results", max_results))
            elif step.tool == "fetch_page":
                max_pages = int(step.args.get("max_pages", max_pages))
                max_chars = int(step.args.get("max_chars", max_chars))
    except (TypeError, ValueError, AttributeError):
        pass
    return max_results, max_pages, max_chars


def run(
    command: str,
    task_id: str | None = None,
    source: str = "text",
    ops_consent=None,
) -> TaskResult:
    """Execute a command end-to-end. Never raises on agent failure — returns TaskResult.

    source: "text" (default, POST /command — quality-first) or "voice"
    (voice_loop — latency-first, prefers voice_model). See _pick_model.

    ops_consent (Track B3): the server's ops ConsentManager authorizing
    destructive plan steps (non-allowlisted shell, overwriting writes).
    None (voice loop, CLI) means no approvals exist — destructive steps
    pause fail-closed with the B3 consent message.

    Track A2 — no silent task loss: task_started + config loads live INSIDE
    the try block, so a corrupt config or a failed log write still emits
    task_failed instead of raising. Empty commands emit task_failed (with
    the text echoed truncated) instead of returning silently.

    Track B1 — LLM planner is primary for free-form commands; any
    LLM/parse/validation failure falls back to the deterministic builders
    (launch/list/code/research). Completion events carry
    ``planner``: "llm"|"fallback". ``source`` still selects the model for
    summarization (and code drafting) via _pick_model.

    Track B3 — memory: redacted task summaries are remembered
    (task_started on entry, task_completed on exit) and the last few
    memories are injected into the LLM planner prompt as bounded DATA
    context. Memory failures never break a run (all calls guarded).
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
                {"task_id": task_id, "error": "Empty command.", "text": command[:200], "planner": "fallback"},
            )
        except Exception:
            pass
        return TaskResult(ok=False, output="Empty command.", task_id=task_id)
    # Memory + recall live OUTSIDE the dispatch try block: every memory call
    # is individually guarded, so a corrupt store can never convert a good
    # run into task_failed. _run_inner owns all lifecycle events.
    store = _load_memory_store_safe()
    _remember_safe(store, "task_started", command[:200])
    memories = _recall_memories_safe(store)
    result = _run_inner(command, task_id, source, ops_consent, memories)
    # Completion summary is metadata only (truncated command, outcome, step
    # count) — tool outputs (file bodies, stdout, page text) are NEVER
    # remembered, so no raw file contents reach the store after read steps.
    _remember_safe(
        store,
        "task_completed",
        f"command={command[:200]} ok={result.ok} steps={result.steps_taken}",
    )
    return result


def _run_inner(
    command: str, task_id: str, source: str, ops_consent, memories: list
) -> TaskResult:
    """Dispatch body of run(): routing, events, planner attribution."""
    try:
        _log_event("task_started", {"task_id": task_id, "text": command[:200], "source": source})

        models = load_models_config()
        tools_cfg = load_tools_config()
        apps_cfg = load_apps_config()
        limits = tools_cfg.agent_limits

        # Track B1 — try the LLM planner FIRST (silent on any failure).
        llm_plan = None
        try:
            try:
                candidate = build_llm_plan(command, tools_cfg, models, memories=memories)
            except TypeError:
                # Patched/older build_llm_plan without the memories kwarg
                # (e.g. B1-era test doubles) — retry without context. Same
                # precedent as researcher.run_research's single-arg
                # llm_summarize fallback. A genuine internal TypeError just
                # raises again below and falls back deterministically.
                candidate = build_llm_plan(command, tools_cfg, models)
            # Re-enforce caps at the orchestration boundary (truncate+reject:
            # overlong or over-deep plans are rejected here, never executed).
            # Track B3: re-enforced WITH the workspace jail — a traversal
            # path falls back to deterministic builders, never executes.
            validate_plan(candidate, limits, tools_cfg.files)
            llm_plan = candidate
        except Exception:
            llm_plan = None

        if llm_plan is not None and llm_plan.steps:
            if any(s.tool == "delegate" for s in llm_plan.steps):
                err = "Plan rejected: delegation lands in B3 — delegate steps are schema-ready but execution-gated"
                _log_event("task_failed", {"task_id": task_id, "error": err, "planner": "llm"})
                return TaskResult(ok=False, output=err, task_id=task_id)
            tools_in_plan = {s.tool for s in llm_plan.steps}
            if tools_in_plan and tools_in_plan <= {"web_search", "fetch_page"}:
                mr, mp, mc = _research_limits_from_plan(llm_plan)
                return _run_research(task_id, command, models, tools_cfg, mr, mp, mc, source, "llm")
            if tools_in_plan and tools_in_plan <= EXECUTOR_TOOLS:
                # Track B3: pure shell/read/list/write LLM plans EXECUTE here
                # (destructive steps pause for laptop consent via the run's
                # ops queue). Genuinely mixed/unknown shapes fall through to
                # the deterministic fallback below.
                from buddy_core.agents.executor import execute_plan

                result = execute_plan(
                    llm_plan, tools_cfg, task_id, _log_event, _make_consent_checker(ops_consent)
                )
                if result.ok:
                    _log_event(
                        "task_completed",
                        {"task_id": task_id, "result": result.output[:2000], "planner": "llm"},
                    )
                    return TaskResult(ok=True, output=result.output, task_id=task_id, steps_taken=result.steps_taken)
                _log_event("task_failed", {"task_id": task_id, "error": result.output, "planner": "llm"})
                return TaskResult(ok=False, output=result.output, task_id=task_id, steps_taken=result.steps_taken)
            if len(llm_plan.steps) == 1 and llm_plan.steps[0].tool == "launch_app":
                key = llm_plan.steps[0].args.get("app_key")
                if isinstance(key, str) and key in apps_cfg.apps:
                    return _run_launch(task_id, key, apps_cfg, tools_cfg, limits, planner="llm")
                # Unknown app_key from the LLM: fall through to the
                # deterministic unknown-app handling below (fail closed).
            elif len(llm_plan.steps) == 1 and llm_plan.steps[0].tool == "list_apps":
                return _run_list_apps(task_id, apps_cfg, tools_cfg, limits, planner="llm")
            # Mixed or otherwise unhandled LLM plans: fall through to the
            # deterministic fallback (fail closed — B3 executes only pure
            # research / pure shell+files / single launch/list shapes).

        app_key = resolve_launch_intent(command, apps_cfg)
        if app_key:
            return _run_launch(task_id, app_key, apps_cfg, tools_cfg, limits, planner="fallback")
        if _is_launch_verb(command):
            known = ", ".join(sorted(apps_cfg.apps)) or "(none registered)"
            _log_event("task_failed", {"task_id": task_id, "error": "Unknown app", "planner": "fallback"})
            return TaskResult(
                ok=False,
                output=f"Unknown app. Registered: {known}. Say 'list apps' for a full list.",
                task_id=task_id,
            )
        if _is_list_apps(command):
            return _run_list_apps(task_id, apps_cfg, tools_cfg, limits, planner="fallback")
        code_target = coder_resolve_target(command)
        if code_target:
            return _run_code(
                task_id, command, code_target, models, tools_cfg, source, planner="fallback", ops_consent=ops_consent
            )
        plan = build_research_plan(command, limits)
        validate_plan(plan, limits)
        mr, mp, mc = _research_limits_from_plan(plan)
        return _run_research(task_id, command, models, tools_cfg, mr, mp, mc, source, "fallback")
    except Exception as exc:
        try:
            _log_event("task_failed", {"task_id": task_id, "error": str(exc), "planner": "fallback"})
        except Exception:
            pass
        return TaskResult(ok=False, output=f"Plan rejected: {exc}", task_id=task_id)
