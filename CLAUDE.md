# Everyday Buddy — Agent Context

You are working in the `everyday-buddy` repo. Read this file, `PROJECT_SPEC.md`, and — for anything touching the phone app, web dashboard, or any visual surface — `DESIGN.md` before doing any work this session.

## What this is

A local-first, multi-agent AI assistant. Runs on the user's laptop, controlled from their phone over LAN. No cloud LLM calls, no telemetry (optional FCM background push excepted — see `SECURITY.md`). Full spec: `PROJECT_SPEC.md`. Full architecture: `ARCHITECTURE.md`.

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
- [x] Phase 3 — Mobile app MVP (code done 2026-09-20: Flutter pairing/chat/tasks/preview per DESIGN.md + server /screen MJPEG with consent flow; 75 tests pass in ~2s incl. real-socket stream test; SDK verification pending — Flutter winget install retrying, then `flutter analyze/test/run`)
- [x] Phase 4 — Proximity & polish (code done 2026-09-26: BLE reader + GET /proximity, SnackBar notifications, hardening + rate limit + replay cap, voice-vs-text routing, SHA-256 pinning, POST /proximity/threshold + CalibrateScreen, authenticated MjpegPlayer with revoke-first stop, maxy wake wiring with alexa stand-in; 164 pytest + 73 dart pass, both analyzes clean; security review PASS with no fixes)
- [ ] v0.1.0 hardware gates — user-confirmed done: voice demo (§1), phone-on-LAN HTTPS (§2). Still human-only: BLE calibration walk (§3), TLS rejection (§4), in-app consent stream (§5).

## Session notes (2026-09-20)

- Mobile app agent wrote 21 files under `mobile/` (pairing, chat, task list, preview placeholder, secure storage, SSE client, proximity fail-closed).
- Streams agent wrote `server/streams.py` (consent manager, MJPEG gen, capture) + wired `/screen` + consent endpoints + 24 tests.
- Fixed a real hang: Starlette 1.6 `StreamingResponse` deadlocks vs httpx 0.28 ASGI transport (which buffers whole responses — infinite streams untestable through it). Added `MJPEGResponse` (custom ASGI response, timeout-polled disconnect) + direct-ASGI stream tests + one real-socket uvicorn test.
- Env: `venv312/` fully installed incl. CrewAI (74 tests passed there); models `qwen2.5:3b` + `llama3.1:8b` + `qwen2.5-coder:7b` all pulled. Pillow 12.3.0 added to pyproject/requirements.
- Next: verify Flutter SDK (`flutter analyze`, `flutter test`, device run), then Phase 4 (BT RSSI, notifications, hardening, v0.1.0).

## Session notes (2026-09-20, cont.)

- CI added (`.github/workflows/ci.yml`: pytest + pip-audit + flutter jobs). Committed + pushed (`4b1611a`).
- UX audit PASS: 5 mobile files fixed (scale tokens, semantics, copy); DESIGN.md status table gained ONLINE/CONNECTING/task-summary rows. Contrast watch noted for next DESIGN pass.
- Flutter SDK: winget has no Flutter package here — earlier attempts silently failed. Manual zip install running via `scripts/install_flutter.ps1` → `C:\src\flutter` (see `flutter_install.log`).
- Standing rule this session: commit + push after every update (remote: `origin/master` @ phoros-code/KREW).

## Session notes (2026-09-20, Phase 4)

- Notifications done (`2e12de6`): SnackBar on task start/complete/fail via SSE + 13 dart tests (unrun — no SDK yet).
- Security review done: docs endpoints disabled, lone-`&`/NUL blocks, UNC/drive/ADS rejections, consent-record cap; 16 new tests; `pip-audit` clean. 91 passed total.
- HUMAN REVIEW items (rule 6): (1) RESOLVED 2026-09-20, confirmed UX-only: decorative-use comment at `require_near` + throttle-blind-to-X-RSSI regression test; (2) RESOLVED 2026-09-20, hard brick kept: ANY authed surface counts as activity (`touch_activity` heartbeats in /events follow-loop + /screen frame wrapper) + distinct-brick test pins `idle_expired` vs `token_expired` as separate settings/predicates/codes; (3) RESOLVED 2026-09-20: per-IP fixed-window throttle (pure-ASGI `RateLimitMiddleware` — NOT BaseHTTPMiddleware, which interposes on `receive` and breaks stream disconnects — 429 `rate_limited` + `Retry-After`, 6 new tests); (4) RESOLVED 2026-09-20, spec fix: /events replay capped to trailing 200 (`tail_log_events`, `EVENTS_REPLAY_LIMIT`; pagination is v1.1), socket test proves mid-stream lines reach followers; 111 passed total.
- Stream-test lesson (paid for in full): never `break` out of httpx `aiter_bytes()` to "hold a stream open" — the break runs `aclose()` and drops the connection under test. Drain continuously in a task group, cancel to disconnect.
- Flutter SDK 3.47.5 installed locally (`C:\src\flutter`, zip verified byte-exact). `flutter analyze`: clean (fixed `jetBrainsMono` casing error + 9 lint infos). `flutter test`: 33 passed locally. Next: device run, then Phase 4 hardware items (BLE calibration, TLS rejection, consent stream check).

## Session notes (2026-09-21, Phase 4 BLE)

- BLE proximity reader done: `BleProximityReader` (flutter_blue_plus 2.3.12, injectable scan seams, stale→null fail-closed) + optional laptop-BT-ID field on pairing screen + secure storage + app wiring (config fetch on pair/boot, watch start/stop, X-RSSI on /command) + `GET /proximity` read-only endpoint (auth, near-or-far) + API.md. 114 pytest + 45 dart tests pass, analyze clean.
## Session notes (2026-09-21, dispatches A/B/C)

- DISPATCH A (`945a68c`): Android SDK via cmdline-tools only (LOCALAPPDATA\Android\Sdk: platform-tools 37, android-36, build-tools 36, licenses accepted; `flutter config --android-sdk` set; doctor clean for Android toolchain). Namespace `com.example.*` → `com.everydaybuddy` (gradle, Kotlin move, pbxproj; zero `com.example` hits left). ⚠️ Still outstanding: full JDK 17 with `javac` (only a JRE runtime was available) — required before `flutter build apk` works.
- DISPATCH B-UX (`f169907`): self-audit 4/4 PASS; token-fidelity fixes on pair/chat/tasks (container radii, labelLarge titles). Analyze + 45 tests green at the time.
- DISPATCH B-backend (review-only, applied as `989e2c8`): SECURITY.md FCM note was STALE (claimed FCM ships — fixed to in-app-SSE-only) + RSSI note completed (GET /proximity, stale→null, X-RSSI single-use) + L62 tweak; `issued_at` runtime-managed note + `token_rotation_days` reserved note in example + CONFIG.md; `tls.*`/`bind_*` confirmed scripts-consumed (serve.ps1 hardcodes 8443 — noted). security.yaml exists locally, gitignored, untracked. ✓
- DISPATCH C (`989e2c8`): HARDWARE_VERIFICATION.md checklist created (6 UNVERIFIED flags inside; notably: no in-app numeric-dBm surface for calibration, laptop consent approval is curl-only).
- Consent-flow gap found during integration (`262cc83`): app never created consent requests so Preview could never reach ready — wired request→await→check→ready/denied (`requestScreenConsent`, `checkScreen(consentId:)`, new `consentRequired/consentDenied` states) + 5 tests. 114 pytest + 50 dart pass, analyze clean.
## Session notes (2026-09-22, remaining-work sprint)

- JDK 17 installed (`C:\src\jdk17`, Temurin 17.0.20.1, `JAVA_HOME` persisted to User env). First `flutter build apk --debug` failed on transient dl.google.com TLS stalls — retry succeeded. **APK built**: `mobile/build/app/outputs/flutter-apk/app-debug.apk` (153.8MB, gitignored), aapt confirms `package=com.everydaybuddy` v0.1.0 + launchable MainActivity.
- Voice stack verified offline: `pip install -e .[voice]` done in venv312 (faster-whisper 1.2.1, openwakeword 0.6.0, piper-tts 1.8.0); Piper model downloaded to `voice/models/` (gitignored). **Round-trip pass**: TTS synth → 2.1s wav → STT transcribed exact text ('Hello buddy, voice check complete.', conf 0.63). Live-mic wake word still needs a human + mic.
- Live TLS server check: /health ok, /proximity 401→200, /command queued AND completed via real model (web_search→fetch→summary in events.jsonl), consent create→approve→200, /screen without grant 403, MJPEG stream 772KB/6s with JPEG SOI. Test server stopped afterwards (port 8443 free).
- NOT tagging v0.1.0 yet: human-only steps remain per HARDWARE_VERIFICATION.md (live-mic demo, phone-on-LAN, BLE calibration, TLS rejection on phone, in-app consent check). Voice models cached (`~/.cache`, `voice/models/`) so the human loop needs no big downloads.

## Session notes (2026-09-22, review dispatches)

- BLE both-platforms: `BleProximityReader` matching is format-agnostic (trim + lowercase compare) but tests only covered MAC — added 3 UUID tests (case-insensitive match, whitespace-trimmed id, wrong-UUID stays FAR). HARDWARE_VERIFICATION §3.7 added: full walk on first phone, then NEAR→FAR→NEAR confirmation-only pass on second phone (same threshold, proves the other ID-format path). 53 dart pass, analyze clean.
- Consent stopgap specified: TESTING.md hardware section now pins the exact `Invoke-RestMethod` request→403→approve→200→deny→403 sequence with state transitions (PENDING→APPROVED/DENIED) and 15-min TTL note, so curl-approve is unambiguous for v0.1.0.
- Voice-vs-text routing (was error-fallback only): new `voice_model` in `config/models.yaml` + `ModelsConfig` + CONFIG.md; `orchestrator.run(..., source="voice"|"text")` — voice prefers fast model (latency), text prefers target (quality), with fallthrough; `voice_loop` passes `source="voice"`, `/command` passes `"text"` explicitly, `task_started` logs `source`. 4 new pytest (voice-fast, text-quality, voice-fallthrough, voice-passes-source). 118 passed + 1 skip.

## Session notes (2026-09-22, pairing-fix dispatch)

- Bug: Android pairing showed spinner-stop-with-no-error. Root cause, two parts: (1) `BuddyApi` used a plain `http.Client()` with zero cert logic, so the self-signed dev cert raised `HandshakeException` on first contact; (2) every `BuddyApi` method caught only `TimeoutException`/`http.ClientException`, so it escaped past `on BuddyApiException` uncaught — `finally` reset `_testing` (spinner stops) and nothing rendered. Phone-browser §2 passing while app failed isolated it to the app TLS layer.
- Fix: SHA-256 pinning per PROJECT_SPEC (`newPinnedClient` via `HttpClient.badCertificateCallback`, trusts exactly the `pair_device.py` fingerprint, empty pin trusts nothing) + new required fingerprint field on Pair screen (validated 64-hex, stored in `SecureStore` as `buddy_cert_fp`) + `Socket/Http/Handshake/TlsException` mapped to `unreachable` (cert-specific message for handshake/TLS) in all 7 methods incl. `validatePairing` probe (was a second unpinned client) + `INTERNET` permission in base manifest (debug was tool-injected; release would have had no network). 7 new dart tests (pin normalize/valid/match-vector + 3 error-mapping). 60 dart pass, analyze clean, 118 pytest + 1 skip.
- Fresh debug APK built: `mobile/build/app/outputs/flutter-apk/app-debug.apk` (177.2MB). User to reinstall + re-pair with IP + token + fingerprint, then §3 walk test.

## Session notes (2026-09-19)

- Done: full Phase 0 per PROMPTS.md. License picked: MIT (`LICENSE` added).
- Env: Win11, i7-14650HX, ~24GB RAM. System Python 3.14 (C:\Python314, repaired missing DLLs) runs the app; `venv312/` (Python 3.12.10) installing in background for CrewAI — crewai's pinned langchain needs numpy<2, no 3.14 wheel. See `scripts/setup_312.ps1`, `pip312.log`.
- Models: `qwen2.5-coder:7b` present; `qwen2.5:3b` + `llama3.1:8b` pulling in background. Orchestrator auto-falls-back to any pulled model (`_pick_model` handles dict- and object-style `ollama.Client.list()`).
- Next: Phase 1 voice (openWakeWord + faster-whisper + Piper) — needs mic + `pip install -e .[voice]` (prefer venv312).
- Blocked: none. Deferred: CrewAI swap (orchestrator boundary is CrewAI-ready via typed plans), webcam endpoint (optional per API.md).

## Session notes (2026-09-26, Phase 4 completion sprint)

- Standing user rules (keep in memory every session): (1) voice demo (§1) + phone-on-LAN HTTPS (§2) confirmed DONE — never re-list as remaining; (2) maximum git commits — one commit per logical change, `phase4: <area> - <change>` style; (3) use `.opencode/agents/` specialists via Task subagents whenever a task matches (mobile/backend/voice/security/testing).
- Committed 5 pending coder/executor slices first (planner build_code_plan, coder, executor, orchestrator wiring, tests — 24 tests green).
- Sprint 1 (Mobile App Builder subagent): `mjpeg_stream: ^1.0.0` (resolved 1.0.1); real widget is `MJPEGStreamScreen` with no headers/client/error-callback, so `MjpegPlayer` owns the pinned stream and reuses `MjpegPreprocessor` for SOI→EOI validation; ready-phase renders player, revoke-first Stop (404/409 tolerated), mid-stream re-probe via checkScreen. 68 dart green, analyze clean.
- Sprint 2 backend (Backend Architect subagent): `POST /proximity/threshold` (require_near, strict-int, -100..-30, atomic 0600 write, in-mem prox_cfg mutate) + 4 tests + API.md/SECURITY.md notes. 159 pytest green.
- Sprint 2 voice (Voice AI Integration Engineer subagent): maxy wiring (resolve_wake_models, WakeConfig, models.yaml wake section, training README + stub script — NO fake .onnx), openWakeWord Model() takes local .onnx paths with auto-onnx framework. 13 voice tests green. NOTE: "maxy" has no community model — custom training needs 50-100 clips (user to provide).
- Sprint 2.3c (Mobile App Builder): `setProximityThreshold` + CalibrateScreen (live RSSI, slider/stepper, walk-test guide, distance log) embedded in Screen tab below preview; onCalibrated re-fetches config. 73 dart green.
- Sprint 3 (Security Architect subagent): HUMAN REVIEW PASS with no fixes — threshold auth/validation/persistence, revoke fail-closed, pinning, proximity fail-closed, throttle blind to X-RSSI, consent TTLs/bounds, error envelopes, mobile human error states all verified. pip-audit: 4 findings all in chromadb 1.1.1 (CrewAI transitive, no fixed versions, NOT reachable from phone surface) — report-only. 164 pytest + 73 dart + both analyzes clean.
- Report-only notes for human: (a) badCertificateCallback bypassable by public-CA cert (unexploitable on RFC1918 LAN); (b) checkScreen maps 429 to unreachable copy (misleading text, fail-closed); (c) non-dict JSON body falls to FastAPI 422 (pre-existing, auth-first).
- Next: §3 BLE walk, §4 TLS rejection, §5 in-app consent stream — all need physical devices. Then tag v0.1.0.

## Session notes (2026-09-26, post-v0.1.0 extras)

- Analysis of remaining spec items: only the optional webcam endpoint was unimplemented (API.md allowed omitting for v1); FCM/CrewAI/events-pagination/OS-prompt are explicitly v1.1-or-later — left alone.
- Webcam done via subagents (Backend + Mobile in parallel): `capture_webcam_jpeg` (lazy cv2, open-read-release per frame, fail-closed), separate `webcam_consent` scope with cross-scope isolation tests both directions, approve/deny/revoke mirror, per-frame re-check; app Screen/Webcam SegmentedButton with per-source consent state (source toggle drops grant, stale mid-flight results discarded). 179 pytest + 89 dart, analyzes clean.
- Security-review note fixed: `ScreenStatus.rateLimited` — 429 probes now show throttling copy, grant kept for Retry.
- `opencv-python>=4.8.0` declared in pyproject only (requirements.txt 3.14 set untouched); opencv NOT installed — runtime dep for webcam use.
- v0.1.0 tag exists; extras above are Unreleased (CHANGELOG) on master past the tag.
