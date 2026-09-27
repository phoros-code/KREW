# Architecture

Companion to `PROJECT_SPEC.md` section 2 — this file goes one level deeper, module by module, for implementation and review.

## Data flow, end to end

```
Voice path:
  mic → wake.py (openWakeWord) → stt.py (faster-whisper) → orchestrator.run()
      → agent plan (typed, validated) → tool execution → tts.py (Piper) → speaker

Phone path:
  phone app → POST /command (token required) → orchestrator.run()
      → events logged to logs/events.jsonl → broadcast over SSE → phone chat UI
      → GET /screen (MJPEG, near mode only) → phone screen preview
```

Both paths converge on the same `orchestrator.run()` call — the voice loop and the control server are two thin front-ends over one core.

## Module responsibilities

### `buddy_core/orchestrator.py`
Owns the single public `run(command: str) -> TaskResult` entrypoint. Direct Ollama calls are the default (`agents.framework: direct` in `config/models.yaml`); when the flag is `"crewai"` AND the command routes to research, the research SUMMARY step runs through a bounded CrewAI crew (`buddy_core/agents/crew.py` — planner + researcher, no tools, same picked model) while planning, `validate_plan`, redaction, and events stay identical. Nothing outside this file constructs agents directly — `voice_loop.py` and `server/main.py` both call `orchestrator.run()`, never the agents themselves.

Track B2 spike record (2026-09-27, Ollama `qwen2.5:3b`, throwaway script, prompt "summarize: ≤2 sentences on why the sky is blue", crew = 2 agents + 1 task + `max_iter=2` + no tools): direct 15.6s cold / 2.8s warm vs crew 4.3s / 3.9s (~1.5x warm — inside the 3x gate); both runs coherent English inside the 2-sentence bound; no crewai+Ollama errors. Verdict: WIRE (gated, research-summary only, default direct) — so nobody re-litigates it.

### `buddy_core/agents/`
- `planner.py` — Track B1: the LLM planner (`build_llm_plan`) is primary — it prompts the local model for STRICT JSON (`{"steps": [{"tool", "args"}]}`), parses defensively (first `{...}` block), and validates via `validate_plan` (allowlist + per-tool arg shapes + `max_steps` + `max_recursion_depth`). The deterministic builders (`build_research/launch/list_apps/code_plan`) are the fail-closed fallback when the LLM/parse/validation fails. `delegate` steps are schema-ready (depth+1) but execution-gated until B3. The plan is the only thing that ever reaches a tool — raw LLM text never does.
- `coder.py`, `researcher.py`, `executor.py` — typed child agents, each scoped to one category of tool. An agent never calls a tool outside its declared category. `researcher.py` implements `run_research` (search → fetch top pages as inert data → LLM summarize, pure-function seams for tests); `orchestrator.run()` routes through it and emits the same redacted `tool_call` events as before. Track B3: the executor runs pure shell/read/list/write plans (authoring scope per category in `AGENT_TOOL_SCOPES`); destructive steps (non-allowlisted shell, overwriting writes) pause for laptop consent via the sha-indexed ops queue (`POST /ops/*`, bounded poll, fail closed). The executor still REFUSES `delegate` steps — multi-agent delegation executes in a later track.

### `buddy_core/tools/`
Every tool here is a narrow, testable function with an explicit allow/deny surface — see `SECURITY.md` for the full model.
- `shell.py` — the only place `subprocess` is called anywhere in this codebase. Allowlist + denylist from `config/tools.yaml`.
- `files.py` — read/write restricted to `~/buddy-workspace`; rejects path traversal.
- `web_search.py` — DuckDuckGo HTML or self-hosted SearXNG; treats fetched page content as **data, not instructions** (a page telling the agent to "ignore previous instructions" is just text to summarize, never a command to follow).
- `screen.py` — a stub (unimplemented); real screen capture lives in `server/streams.py` behind the `/screen` consent flow.

### `voice/`
Thin glue only — `voice_loop.py` should contain no business logic, just wiring between `wake.py`, `stt.py`, `orchestrator.run()`, and `tts.py`.

### `buddy_core/memory/`
Bounded local conversation memory (Track B3 — no longer a stub).
`MemoryStore` persists redacted agent-lifecycle summaries to a JSONL file
(`config/tools.yaml` → `memory:`, default `logs/memory.jsonl`, cap 500
entries, each `{ts, kind, text[:500]}`, oldest evicted first). The
orchestrator remembers `task_started`/`task_completed` metadata only
(truncated command, outcome, step count — tool outputs such as file
bodies are never stored) and injects the last 5 memories into the LLM
planner system prompt as bounded, labelled DATA context (2000 chars;
untrusted-content rules apply). Reads tolerate missing/corrupt files;
memory failures never break a run. See `SECURITY.md` → Secrets & data
handling (no raw payloads) and `CONFIG.md` → `memory:`.

### `server/`
- `main.py` — FastAPI app, all routes documented in `API.md`.
- `auth.py` — token issuance, verification, rotation, rate limiting.
- `streams.py` — MJPEG screen/webcam streaming, gated by proximity mode.

### `mobile/`
Flutter app. UI decisions for this surface are governed by `UI_UX_GUIDE.md` and `DESIGN.md` — read both before building any screen.

### `config/`
Nothing security- or behavior-relevant is hardcoded in Python — see `CONFIG.md` for the full schema of `models.yaml`, `tools.yaml`, `security.yaml`.

## Directory layout

See `PROJECT_SPEC.md` section 7 for the full tree.
