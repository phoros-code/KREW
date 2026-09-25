# Changelog — Everyday Buddy

## Unreleased (post-v0.1.0)
- **Webcam preview**: consent-gated `GET /webcam` (separate consent scope —
  screen grants never authorize webcam and vice versa), `capture_webcam_jpeg`
  via OpenCV (lazy import, fail-closed), approve/deny/revoke mirror, 15
  server tests incl. cross-scope isolation. App: Screen/Webcam segmented
  toggle in Screen tab with per-source consent state. `opencv-python>=4.8.0`
  declared in `pyproject.toml`. +16 dart tests (89 total).
- **Honest 429 copy**: `ScreenStatus.rateLimited` — throttled preview probes
  now say "slowing down, wait and retry" instead of "no route"; grant kept
  for Retry.

## v0.1.0 (2026-09-26) — Phase 4 completion, code-complete

Phase 0–3 were delivered in earlier sessions (see `CLAUDE.md` session notes).
This release completes all code sprints for v0.1.0.

### Added
- **Screen preview, real frames**: `MjpegPlayer` widget (authenticated + SHA-256
  pinned TLS, `MjpegPreprocessor` frame validation) rendered in the `ready`
  phase; `mjpeg_stream: ^1.0.0` (resolved 1.0.1) added to `pubspec.yaml`.
- **Consent revoke from app**: `BuddyApi.revokeScreenConsent`,
  `screenStreamUrl`, `authHeaders`; Stop button revokes first (404/409
  tolerated, local reset unconditional); mid-stream drops re-probe via
  `checkScreen` (no blind reconnect, no autostart).
- **Proximity threshold endpoint**: `POST /proximity/threshold` (near-only,
  strict-int, `-100..-30` dBm, atomic 0600 write, in-memory update) + 4 tests
  + `API.md` / `SECURITY.md` notes.
- **In-app calibration**: `CalibrateScreen` (live RSSI, slider/stepper,
  walk-test guide, distance log, human error states) embedded in the Screen
  tab; `setProximityThreshold` with client-side bounds check; applying
  re-fetches server config. +5 dart tests.
- **"maxy" wake-word wiring**: `resolve_wake_models` (custom
  `voice/models/maxy.onnx` when present, `alexa` stand-in otherwise),
  `wake:` section in `config/models.yaml` + `WakeConfig`, training README +
  honest `scripts/train_wakeword.py` stub (no fake model bytes). +5 tests.
  NOTE: custom "maxy" training needs 50–100 user-provided clips — pending.
- **Coder/executor slices**: `build_code_plan`, `CoderAgent`
  (path-from-command, content-from-LLM, workspace jail), `ExecutorAgent`
  (shell+files scope, fail-fast), orchestrator `_run_code` wiring + tests.

### Security
- Human review PASS with no fixes (auth, tokens, TLS, proximity gating).
- `pip-audit`: 4 findings, all in `chromadb 1.1.1` (CrewAI transitive, no
  fixed versions published, NOT reachable from the phone surface) —
  report-only.

### Hardware verification
- User-confirmed done: voice demo (§1), phone-on-LAN HTTPS (§2).
- Still human-only (need physical devices): BLE calibration walk (§3),
  TLS rejection (§4), in-app consent stream (§5). See
  `HARDWARE_VERIFICATION.md`.

### Test counts
- Python: 164 passed, 1 skipped (Windows symlink privilege).
- Dart: 73 passed. `flutter analyze`: clean on both sides.
