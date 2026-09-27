# Changelog — Everyday Buddy

## Unreleased (KREW remediation)
- **CI sync**: `cryptography==50.0.1` added to `requirements.txt` (was
  imported by tests + `gen_cert.py` but missing from the light CI set);
  dropped the unused `sse-starlette` pin. chromadb CVEs documented as
  accepted risk in SECURITY.md (newest crewai still pins `chromadb~=1.1.0`,
  no fixed version published, dependency unreachable from the app surface).
- **Setup scripts**: `scripts/mic_check.py` (list inputs + RMS capture
  check) and `scripts/download_voice_models.py` (stdlib-only Piper fetch)
  with 13 hermetic tests. HARDWARE_VERIFICATION §1 rewritten onto them;
  voice entry points and per-OS Bluetooth-ID procedures documented.

## v0.2.1 (2026-09-27) — Security-review follow-ups (Track E)

E1 review verdict was FAIL on rotation semantics; re-verification PASS after
these fixes. No BLOCKERs remain; residual NOTEs ride.

- **Rotation recovery**: an external token rotation resets the idle clock
  (rotate-to-recover works after long idle) and clears lockouts. A
  same-token config touch preserves both — a threshold edit no longer
  amnesties an attacker's lockout. Mid-load second writes converge via a
  bounded re-read (worst case: one request of staleness).
- **Search backends pinned**: SearXNG and DuckDuckGo calls go through the
  same DNS-pinned, manually-redirected transport as page fetches; a
  loopback SearXNG URL fails closed; redirected POSTs continue as bodyless
  GET (request bodies are never forwarded to a new host).

## v0.2.0 (2026-09-27) — Hardening (Track A)

All 13 audit CRITICALs fixed; no new capabilities. Upgrade note: consent
approve/deny now require the laptop (loopback or `X-Buddy-Approval` secret);
legacy `security.yaml` files get a secret backfilled on first boot. The
`POST /webcam` + `ScreenStatus.rateLimited` extras from post-v0.1.0 are
included.

### Auth & sessions (A1)
- Live `/events`, `/screen`, `/webcam` streams re-verify the token every
  tick — no stream outlives expiry, idle timeout, or rotation. Stream
  keep-alives no longer refresh the idle clock (opt-in flag
  `streams_follow_counts_as_activity`, default off).
- Per-IP lockout (one bad host can't brick the phone), `RateLimiter`
  eviction, atomic locked `security.yaml` writes, typed error on corrupt
  config, `/command` length/type/concurrency caps + Ollama timeouts,
  laptop-only `scripts/rotate_token.py` (named in SECURITY.md).

### Event pipeline (A2)
- Tool args redacted to length + SHA-256 in logs and SSE (no file contents,
  no command text). 5 MB log rotation, seek-from-end tail, file I/O off the
  event loop. `task_failed` on config/log failure and on empty commands.
  Custom `/events` ASGI response (no double `receive` consume) with
  `retry:` + `: ping` keepalive. Uniform `{error:{code,message}}` envelope
  for 422/404/405.

### Consent, second-party (A3, BREAKING)
- Approve/deny require loopback origin or `X-Buddy-Approval`
  (`consent_approval_secret`, auto-backfilled); phone-token-only approval →
  403 `approval_forbidden`. Revoke stays phone-gated. One capture handle per
  stream, 1 stream per grant + 4 per IP (429 `stream_limit`). Streams
  settings configurable. API.md / SECURITY.md / HARDWARE §5 rewritten.

### Agent surface & config truth (A4)
- SSRF guard + 1 MB fetch ceiling in web search. Launch/list-apps go through
  validated plans. Deleted the unwired `allow_outside_workspace` key. Wake
  word/model/threshold honored from `models.yaml` (was hardcoded).
  `fail_mode: near` rejected at load. Scripts read TLS/bind from
  `security.yaml`. Voice replies use temp dirs. Deps declared truthfully
  (cryptography, pyaudio; sse-starlette dropped). Stub modules called out
  honestly in ARCHITECTURE.md.

### Mobile critical path (A5)
- Fresh-install command deadlock fixed (stream-open counts as connected).
  Header inset overflow, frozen-frame-on-revoke (onDone + stall watchdog),
  grant leaks on toggle/unmount, tab/background suspend with revoke,
  boot-failure retry state, strict host validation, SSE backoff + stall
  reconnect, BLE runtime permission + explanatory causes + rescan backoff,
  dispose ordering, connect leak, empty-state/Retry/draft fixes.
  `permission_handler` added.

### Tests (A6)
- 296 pytest (+117) incl. 15-route 401 matrix, capture real path, script
  tests. 183 dart (+94) incl. full SSE-parser coverage, widget smokes for
  all screens, theme-token pins, integration smoke shell. CI: superseded
  runs cancelled, coverage artifact collected.

## v0.1.0 (2026-09-26) — Phase 4 completion, code-complete

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
