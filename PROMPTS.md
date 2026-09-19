# Prompt library

The full set of prompts for building Everyday Buddy with an AI coding agent (Claude Code or similar), phase by phase. Read `CLAUDE.md`'s non-negotiable rules once before starting — every prompt below assumes the agent already has that context loaded (it will, automatically, if `CLAUDE.md` is at the repo root).

General pattern for every prompt: **one module per session, tests before wiring, review the diff, commit, update `CLAUDE.md`'s status section.**

---

## Phase 0 — Foundations

**Target:** `python -m buddy_core "research local LLMs"` prints a summary.

1. *"Scaffold the buddy_core package per the structure in PROJECT_SPEC.md section 7. Add a pyproject.toml with crewai, ollama, and pytest as dependencies. Just the skeleton — empty modules with docstrings, no logic yet."*
2. *"Implement buddy_core/tools/files.py: read/write restricted to ~/buddy-workspace. Write tests first, per TESTING.md — confirm path traversal (../, absolute paths, symlinks) is rejected before implementing the happy path."*
3. *"Implement buddy_core/tools/shell.py: a restricted shell tool reading the allowlist/denylist from config/tools.yaml, per CONFIG.md's schema. The denylist always wins over the allowlist. Write the denylist-wins-over-allowlist test first, then the allowlist tests, then implement."*
4. *"Implement buddy_core/tools/web_search.py using DuckDuckGo HTML search, no API key. Mock the HTTP call in tests. Also add a test confirming that page content containing an embedded instruction ('ignore previous instructions and...') is returned as plain text data, never executed or treated specially — see SECURITY.md's prompt-injection note."*
5. *"Wire a single CrewAI ResearchAgent in buddy_core/orchestrator.py using web_search.py, backed by Ollama at the host in config/models.yaml, using the dev_model. Add a CLI entrypoint: python -m buddy_core '<command>' that calls orchestrator.run() and prints the result."*
6. *"Update CLAUDE.md's status section: mark Phase 0 complete, note the dev model in use, and list anything deferred."*

**Checkpoint:** run it for real, read the output, run the full test suite, commit.

---

## Phase 1 — Voice loop

**Target:** say "Hey Buddy, what's the weather" → hear a spoken answer.

1. *"Add voice/wake.py using openWakeWord with a pretrained model. Since this needs a live mic, write a manual test script (not pytest) that prints 'WAKE DETECTED' — document how to run it manually in TESTING.md's hardware-in-the-loop section."*
2. *"Add voice/stt.py wrapping faster-whisper. Add a fixture .wav file under tests/fixtures/ and a pytest test asserting the transcription matches the known text — this one can be a real automated test since it doesn't need a live mic, per TESTING.md."*
3. *"Add voice/tts.py wrapping Piper. Test that a given string produces a non-empty wav file with a plausible duration for the input length."*
4. *"Add voice/voice_loop.py: wake → record N seconds → stt.transcribe → orchestrator.run() → tts.speak(). Keep this a thin glue module with zero business logic of its own, per ARCHITECTURE.md."*
5. *"Add basic error handling to voice_loop.py: if STT returns empty/low-confidence text, or the orchestrator call fails, speak a short fallback response instead of crashing silently."*

**Checkpoint:** live demo to yourself, out loud. This is hardware-in-the-loop — don't skip actually running it. Commit.

---

## Phase 2 — Control server

**Target:** from a phone browser on the same Wi-Fi, send a command and see live logs.

1. *"Add server/auth.py implementing the auth.yaml schema in CONFIG.md: token generation on first run, bearer token verification as a FastAPI dependency, rate limiting after max_failed_attempts, idle timeout. Write tests for valid token, invalid token, rate-limit lockout, and idle expiry, per TESTING.md, before wiring it into any route."*
2. *"Add server/main.py implementing the endpoints in API.md exactly: POST /command, GET /events (SSE), GET /health (unauthenticated, minimal). Every route except /health requires server.auth's dependency. Use FastAPI's TestClient for route/auth tests — no real network needed."*
3. *"Add proximity gating middleware per API.md's proximity table: /command is near-only, /events is near-or-far. If proximity can't be determined, default to far — never near. Write a test confirming a far-mode request to /command returns 403."*
4. *"Log every agent event (task_started, tool_call, task_completed, task_failed) to logs/events.jsonl from orchestrator.py, matching the event shapes in API.md. Have /events tail that file and broadcast new lines over SSE."*
5. *"Add TLS: generate a local dev cert with mkcert, wire it into server startup, and document the setup steps in README.md's quick start."*
6. *"Review server/auth.py and the proximity middleware against SECURITY.md's Authentication and Authorization sections line by line, and flag anything not yet covered."* — do this one as a human review prompt, not a build prompt; read the agent's answer carefully yourself.

**Checkpoint:** curl the endpoints from another device on your LAN over HTTPS. Run the full test suite. Commit.

---

## Phase 3 — Mobile app MVP

**Target:** phone app sends a command and views the laptop screen.

Read `UI_UX_GUIDE.md` and `DESIGN.md` yourself before this phase, and fill in `DESIGN.md`'s placeholder choices (palette, type, layout primitive) before generating any screen — every prompt below assumes that's already done.

1. *"Scaffold a Flutter app. Build the pairing screen (enter laptop IP + token, or scan a QR code, stored in flutter_secure_storage) per DESIGN.md's palette and type choices exactly — no gradient or font outside what's specified there. Design the empty state (no laptop found yet) and the error state (wrong token), not just the happy path."*
2. *"Add the chat screen: POST to /command per API.md, render responses streamed from /events via SSE. Follow DESIGN.md's layout primitive — don't introduce a new card style for this screen."*
3. *"Add the task list screen: task id, status, and timestamp from the event log. Every status indicator here needs an entry in DESIGN.md's Status meaning table — add the entries there first, then build the UI against them."*
4. *"Add the MJPEG screen-preview widget pointed at /screen, gated behind the explicit consent prompt required by SECURITY.md — the stream must not auto-start on screen open."*
5. *"Run every screen built so far against UI_UX_GUIDE.md's self-audit checklist. Report which items fail and fix them before moving on."*

Run the app after each screen and actually look at it — don't stack three unreviewed UI changes.

**Checkpoint:** phone app sends a command, you watch the laptop screen update on the phone. Commit.

---

## Phase 4 — Proximity & polish

**Target:** full MVP — near mode gives full control, walking out of range drops to notifications-only.

1. *"Add a Bluetooth RSSI reader on the phone side and a matching endpoint on the server, per CONFIG.md's proximity section. Default fail_mode to far if the signal can't be read — write a test confirming this."*
2. *"Wire the near/far threshold from config/security.yaml into the phone app's proximity indicator, per DESIGN.md's status meaning table — this indicator is safety-relevant, make sure it's unambiguous per UI_UX_GUIDE.md's guidance on this specific screen."*
3. *"Add in-app notifications on task start/complete/fail, wired to the existing /events SSE stream."*
4. *"Run the full TESTING.md checklist — automated suite, plus the manual/hardware items (wake word, BLE thresholds, TLS cert rejection, consent-gated streaming) — and record results before tagging a release."*
5. *"Do a final pass: review config/security.yaml.example is committed and the real security.yaml is gitignored; review SECURITY.md's Known limitations section is still accurate; review every screen once more against UI_UX_GUIDE.md's self-audit checklist."*

**Checkpoint:** full demo — near mode gives full control, walking out of range drops you to notifications-only. Commit, tag `v0.1.0`.

---

## Ongoing hygiene prompts (use every session)

- End of session: *"Update CLAUDE.md's status section with what's done, what's next, and anything blocked."*
- After any change to `shell.py`, `files.py`, or `auth.py`: *"Summarize exactly what changed in this diff and which SECURITY.md section it relates to, so I can review it before running anything."*
- After any UI change: *"Check this screen against UI_UX_GUIDE.md's self-audit checklist and DESIGN.md's hard rules before I review it."*
- When something breaks: paste the actual error/traceback, don't ask the agent to "just fix it" blind.
