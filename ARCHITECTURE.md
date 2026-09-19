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
Owns the CrewAI crew definition and the single public `run(command: str) -> TaskResult` entrypoint. Nothing outside this file constructs agents directly — `voice_loop.py` and `server/main.py` both call `orchestrator.run()`, never the agents themselves.

### `buddy_core/agents/`
- `planner.py` — decomposes a command into a typed plan (a list of tool calls with arguments), capped by `config/tools.yaml`'s `max_steps` and `max_recursion_depth`. The plan is the only thing that ever reaches a tool — raw LLM text never does.
- `coder.py`, `researcher.py`, `executor.py` — typed child agents, each scoped to one category of tool. An agent never calls a tool outside its declared category.

### `buddy_core/tools/`
Every tool here is a narrow, testable function with an explicit allow/deny surface — see `SECURITY.md` for the full model.
- `shell.py` — the only place `subprocess` is called anywhere in this codebase. Allowlist + denylist from `config/tools.yaml`.
- `files.py` — read/write restricted to `~/buddy-workspace`; rejects path traversal.
- `web_search.py` — DuckDuckGo HTML or self-hosted SearXNG; treats fetched page content as **data, not instructions** (a page telling the agent to "ignore previous instructions" is just text to summarize, never a command to follow).
- `screen.py` — periodic screenshot capture via `mss`, gated behind the same consent flow as `/screen`.

### `voice/`
Thin glue only — `voice_loop.py` should contain no business logic, just wiring between `wake.py`, `stt.py`, `orchestrator.run()`, and `tts.py`.

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
