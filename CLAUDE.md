# Everyday Buddy — Agent Context

You are working in the `everyday-buddy` repo. Read this file, `PROJECT_SPEC.md`, and — for anything touching the phone app, web dashboard, or any visual surface — `DESIGN.md` before doing any work this session.

## What this is

A local-first, multi-agent AI assistant. Runs on the user's laptop, controlled from their phone over LAN. No cloud LLM calls, no telemetry. Full spec: `PROJECT_SPEC.md`. Full architecture: `ARCHITECTURE.md`.

## Non-negotiable rules for this codebase

1. **No agent ever calls `subprocess` / `os.system` directly.** All shell access goes through `buddy_core/tools/shell.py`, which enforces the allowlist/denylist in `config/tools.yaml`. See `SECURITY.md`.
2. **No agent writes files outside `~/buddy-workspace`.** All file access goes through `buddy_core/tools/files.py`. See `SECURITY.md`.
3. **Every tool gets a test before it's wired into an agent.** Test the tool in isolation first. See `TESTING.md`.
4. **Raw LLM output never reaches a tool call unparsed.** Plans are typed and validated before execution — never string-interpolate model output into a shell command or file path.
5. **Any UI work reads `DESIGN.md` first.** Don't let default framework/library styling ship unreviewed — see `UI_UX_GUIDE.md` for why this matters and what to avoid.
6. **Anything touching auth, tokens, TLS, or proximity gating gets a human review**, not just a passing test. Flag these changes explicitly when you finish them.

## Architecture decisions (current)

- Agent framework: CrewAI
- LLM runtime: Ollama at `http://localhost:11434`
- Dev model: `qwen2.5:3b` (fast iteration) — Target model: `llama3.1:8b`
- Control server: FastAPI
- Mobile app: Flutter
- Wake word: openWakeWord — STT: faster-whisper — TTS: Piper
- Config lives in `config/*.yaml`, never hardcoded — see `CONFIG.md`

## Conventions

- Every tool in `buddy_core/tools/` has a matching test in `tests/`
- Every agent in `buddy_core/agents/` takes a `Config` object, not hardcoded paths
- Every server endpoint in `server/main.py` requires the auth dependency from `server/auth.py` unless explicitly documented otherwise in `API.md`
- Commit messages: `phase0: add shell tool allowlist` style — see `CONTRIBUTING.md`

## Status

*(Update this section at the end of every session — what's done, what's next, what's blocked. This is what makes the next session fast instead of re-explaining context.)*

- [x] Phase 0 — Foundations (done 2026-09-19: scaffold + files/shell/web_search tools + planner caps + ollama-direct orchestrator + CLI; 27 tests pass, 1 skip (win symlink priv); live `buddy "research ..."` verified vs qwen2.5-coder:7b)
- [x] Phase 1 — Voice loop (code done 2026-09-19: wake/stt/tts/voice_loop + 7 loop tests; hardware verification pending — mic + `pip install -e .[voice]` + Piper model download + live out-loud demo)
- [x] Phase 2 — Control server (code done 2026-09-19: token auth + lockout/idle/rotation, /command /events /health, proximity fail-closed, JSONL events, TLS gen_cert + serve + pair_device scripts; HTTPS verified locally via curl — /health ok, /command queued, unauth 401; phone-on-LAN check pending)
- [ ] Phase 3 — Mobile app MVP
- [ ] Phase 4 — Proximity & polish

## Session notes (2026-09-19)

- Done: full Phase 0 per PROMPTS.md. License picked: MIT (`LICENSE` added).
- Env: Win11, i7-14650HX, ~24GB RAM. System Python 3.14 (C:\Python314, repaired missing DLLs) runs the app; `venv312/` (Python 3.12.10) installing in background for CrewAI — crewai's pinned langchain needs numpy<2, no 3.14 wheel. See `scripts/setup_312.ps1`, `pip312.log`.
- Models: `qwen2.5-coder:7b` present; `qwen2.5:3b` + `llama3.1:8b` pulling in background. Orchestrator auto-falls-back to any pulled model (`_pick_model` handles dict- and object-style `ollama.Client.list()`).
- Next: Phase 1 voice (openWakeWord + faster-whisper + Piper) — needs mic + `pip install -e .[voice]` (prefer venv312).
- Blocked: none. Deferred: CrewAI swap (orchestrator boundary is CrewAI-ready via typed plans), webcam endpoint (optional per API.md).
