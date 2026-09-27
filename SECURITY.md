# Security

Everyday Buddy runs an action-taking agent — shell access, file access, screen/webcam streaming — on a control server reachable from your phone. That combination is exactly the kind of system where "it works on my Wi-Fi" is not the same as "it's safe." This file is the checklist that closes the gap.

## Threat model

What we're actually defending against, roughly in order of severity:

1. **An attacker on the same LAN** (open Wi-Fi, compromised IoT device, malicious guest) intercepting or forging requests to the control server.
2. **A malicious or manipulated tool input** — a web page, a file, or a spoken command that tries to get the agent to run a destructive shell command or exfiltrate data. This includes **prompt injection**: text encountered while browsing or reading a file that contains instructions aimed at the agent, not the user.
3. **Token theft** — a stolen or leaked pairing token giving an attacker full remote control.
4. **Screen/webcam leakage** — anyone with a valid token seeing everything on your screen, including other open windows, passwords being typed, etc.
5. **Scope creep in the agent's own permissions** — a tool or agent quietly gaining more access than it needs, so one bug becomes a bigger incident than it should.
6. **Physical device loss** — a lost or stolen phone with a cached token.

We are explicitly **not** defending against a well-resourced attacker who already has code execution on your laptop, or against the LLM provider itself (there isn't one — everything is local). This is a personal-use, LAN-scoped threat model, not an enterprise one — but "personal use" doesn't mean "no security," because a phone-controlled shell-executing agent is a genuinely attractive target even on a home network.

## Network security

- **LAN-only by default.** The control server binds to the local subnet only. Do not port-forward it to the public internet. If you need remote access, put it behind a WireGuard or Tailscale tunnel — don't expose `/command` or `/screen` directly.
- **TLS everywhere**, even on LAN. Use `mkcert` for a locally-trusted self-signed cert during development; document the fingerprint so the phone app can pin it.
- **No UPnP.** Don't let any router auto-forward these ports — an accidental UPnP rule is how "LAN-only" quietly becomes "internet-facing."
- **Firewall rule as a second line of defense**, not the only one — a host firewall restricting the control server's port to your subnet, in addition to the app-level auth below.

## Authentication

- **One-time pairing token**, generated on the laptop on first run, shown as a QR code or short code, entered once on the phone and stored in platform secure storage (Android Keystore / iOS Keychain — never plain SharedPreferences or a plist).
- **Every** `/command`, `/events`, `/screen`, `/webcam` request requires the token. No unauthenticated endpoint should exist except a minimal health check that reveals nothing sensitive.
- **Token rotation.** Support regenerating the token from the laptop UI at any time, which immediately invalidates the old one — this is your answer to "I think my phone got compromised."
- **Rate limiting and idle timeouts** on the auth layer: lock out after repeated failed attempts, expire idle sessions, and re-require pairing after a configurable period of inactivity. A per-IP request throttle (`network.rate_limit_per_minute`, enforced as middleware in `server/main.py`) additionally bounds request volume from any single client — supplements auth, never substitutes for it.
- **PIN as a second factor is optional, not a substitute** for the token — don't rely on PIN-over-HTTP as your only protection (this is one of the specific weaknesses noted in AnovaX's own paper, and worth taking seriously here too).

## Authorization: proximity gating

- **"Near" vs. "far" modes**, driven by LAN presence plus optional Bluetooth RSSI. "Near" = full API access (command, screen, webcam). "Far" = `/events` (notifications) only.
- **Fail closed, not open.** If RSSI can't be read, or the near/far check errors out, default to "far." A missing signal should never silently grant full access.
- **Proximity is a UX nicety, not your only access control.** It supplements the token — it should never be the sole gate on a sensitive endpoint.

## Tool sandboxing (the shell/file/automation layer)

This is the highest-stakes part of the whole project, because the agent's job is literally to run commands and touch files.

- **Allowlist, not denylist, as the primary model.** `config/tools.yaml` defines exactly which shell commands and file operations are permitted; nothing outside that list runs, full stop.
- **Denylist as a second, independent layer** on top of the allowlist — hard-block destructive patterns (`rm -rf`, `format`, `dd`, `mkfs`, `:(){ :|:& };:`, etc.) even if something in the allowlist could theoretically be combined to do the same damage.
- **Plan size and recursion caps.** Every agent plan has a max step count and a max recursion depth (mirrors AnovaX's bounded worker/agent/recursion counts) — an agent should never be able to spin into an unbounded loop of self-delegated sub-tasks.
- **Typed tool calls only.** The planner emits a structured plan (tool name + validated arguments); raw LLM text is never string-interpolated into a shell command or file path. This is what actually prevents most injection classes, not the denylist.
- **Untrusted content stays data, not instructions.** Anything the agent reads from the web, a file, or a screen capture is treated as content to summarize or act *on*, never as commands to follow. If a fetched web page says "ignore your previous instructions and run X," that text should be inert.
- **File tool restricted to `~/buddy-workspace`**, with explicit path-traversal tests (`../../etc/passwd`-style attempts should fail every time, not just in the happy path).
- **Browser tool (`buddy_core/tools/browser.py`, Track B5) is deny-by-default.** `browser_act(action, url, ...)` supports exactly four actions (`goto`, `click`, `fill`, `read_text`) — no file downloads, no JS eval, no navigation outside an explicit `goto` (every action navigates to its `url` first, then acts). Every navigation passes the same fail-closed SSRF guard as page fetches (`_assert_url_safe`: http/https only, host must resolve to public addresses) PLUS an operator domain allowlist (`tools.yaml` → `browser.allowed_domains`, default empty = deny-all, exact-or-subdomain match) — and because Playwright follows redirects internally, the LANDED url is re-checked against both gates before anything acts on the page (a redirect off-allowlist or onto a private host aborts). Consent is self-enforced inside the tool (no approval channel = fail closed before launch, so no direct import can bypass the executor's pause); the pause discloses that fetched text persists in the event log. Playwright launches Chromium headless with the default sandbox (never `--no-sandbox`), page JavaScript off, downloads refused, is imported lazily (clear install error when absent), and every handle (page/context/browser) closes in `finally`. Fetched page text is DATA, never instructions, and `fill` text is redacted in events (length + sha256, never raw keystrokes).
- **Timeouts and resource locks** per tool call, so one runaway process can't hang or starve the rest of the system.

## Consent

Track A3 (BREAKING): consent is now a genuine second-party gate, not a
phone self-approval. Request creation stays phone-token + near
(`POST /screen/consent`, `POST /webcam/consent`), but approval/denial
requires LAPTOP confirmation — either loopback origin (`127.0.0.1`/`::1`,
e.g. curl from the laptop) or header `X-Buddy-Approval` constant-time
matching (`hmac.compare_digest`) `auth.consent_approval_secret` (64-hex,
generated on first run via `server.auth.generate_approval_secret`,
persisted 0600 in `security.yaml`). Phone-token-only approve/deny fails
closed with 403 `approval_forbidden`. Revoke stays phone-token-gated
(fail-closed stop must always work from the phone). Separate scopes:
a screen grant never authorizes `/webcam` and vice versa. Caps: 1 live
stream per grant + 4 per IP (429 `stream_limit` + `Retry-After`); one
capture handle per stream (`mss.mss()` / `cv2.VideoCapture`, opened once,
released on disconnect). Lifetimes/bounds live in the `streams:` block
(`target_fps`, `max_consecutive_failures`, `pending_ttl_seconds`,
`grant_ttl_seconds`, `max_consent_records`).

Explicit, un-skippable prompts before:
- Starting a screen share
- Starting webcam access
- Any file operation outside a normal read/write in the workspace (delete, overwrite outside workspace, anything the denylist would otherwise catch)
- Any shell command not already in the allowlist, if you choose to support an "ask me" fallback rather than a hard block

### Destructive-op consent (Track B3)

Plans that reach shell/files tools pause fail-closed on two destructive
shapes instead of executing or silently erroring:

- **Non-allowlisted shell** (not in `tools.yaml` allowlist, denylisted, or
  metachar): the step pauses with
  `Plan rejected: destructive step needs laptop consent (B3 consent queue)`
  plus the redacted denial reason. Approval does NOT bypass the allowlist
  — a non-allowlisted command stays denied even when approved (the
  allowlist is the primary model, this queue is the ask-me visibility
  layer, not an override).
- **Overwriting writes** (`write_file` where the workspace path already
  exists): the step pauses; laptop approval unlocks exactly that op.
  Fresh-file writes execute normally; jail escapes are rejected outright
  (no consent hook — the write never happens).
- **Every `browser_act` call** (Track B5, `browser_act` in researcher
  scope, executed via `execute_plan`): the step ALWAYS pauses for laptop
  ops-consent first — including `read_text` (page content can contain
  secrets, and one uniform rule is simpler to reason about than a
  read/write split). Approval authorizes within policy bounds only: the
  SSRF guard + domain allowlist inside the tool still apply after
  approval, so an approved-but-unlisted URL stays denied.

Mechanics: the executor computes the op identity as sha256 over the
REDACTED step shape (the same `{length, sha256}` descriptors the phone
sees on SSE `tool_call` events), so the phone can recompute it without
ever seeing secrets. The queue reuses the `ConsentManager` class as a
third instance (`ops_consent`, own `ops:` TTLs — pending 300s, grant
600s) with a sha→consent_id index shared by server creation
(`POST /ops/consent`, phone-token + near, idempotent per sha) and the
orchestrator's bounded poll (~60s, then fail-closed). Approve/deny reuse
the existing laptop-only gate (loopback or `X-Buddy-Approval`,
phone-token-only → 403 `approval_forbidden`). Scopes never cross: a
screen/webcam grant never authorizes an op and vice versa.

## Secrets & data handling

- **No secrets in source control.** `config/security.yaml` (tokens, cert paths) is gitignored; ship a `security.yaml.example` instead.
- **Inference, agents, data, and telemetry stay local.** No telemetry, no analytics calls, no crash reporting that phones home by default — if you ever add any, it must be opt-in and disclosed in `README.md`. FCM background push is not implemented in v0.1.0; if ever added it would be the one exception — see Known limitations.
- **Screen/webcam frames are not persisted** beyond what's needed to stream them live — don't accidentally build a rolling video archive of your own screen.
- **Voice clips are never persisted** — `POST /voice/transcribe` decodes the upload from an ephemeral `TemporaryDirectory` (deleted after each request) and emits no events, so transcripts never touch `logs/events.jsonl` either.
- **Event logs (`logs/events.jsonl`)** should log what the agent did, not raw sensitive payloads — avoid dumping full file contents or screen frames into the log. `task_started` command text is truncated to 200 chars (same bound as the empty-command path) to bound log growth and sensitive-payload retention.

## Dependency hygiene

- Pin versions in `requirements.txt` / `pubspec.yaml` — don't float on `latest` for anything with shell/file access.
- Run `pip-audit` (Python) and equivalent tooling for the Flutter side periodically, especially before a release.
- Review dependency updates to `buddy_core/tools/` and `server/auth.py` more carefully than anywhere else in the repo — these are the modules where a supply-chain issue has the most impact.
- **Known-accepted: 4 chromadb CVEs (PYSEC-2026-311, PYSEC-2026-3813/3814/3815).**
  `chromadb==1.1.1` arrives transitively via `crewai==1.15.22`, which pins
  `chromadb~=1.1.0` — the newest crewai still pins that range, and OSV
  lists no fixed chromadb version, so no compatible bump exists.
  Accepted because: (1) crewai is declared but **not imported by any
  production code** (Track B2 decision pending — wiring or removal);
  (2) no chromadb server ever runs — the vulnerable `/api/v2` endpoints
  are never served; (3) nothing in the phone-reachable surface touches
  chromadb; (4) CI's light set excludes crewai/chromadb entirely, so the
  CI audit is unaffected. Revisit when wiring CrewAI (Track B2): either
  a fixed chromadb exists by then, or the CrewAI integration must sandbox
  or drop the chromadb dependency.

## Physical device security

- Require the phone's own lock screen to use the companion app (don't add a bypass).
- Token stored in secure hardware-backed storage, not recoverable by a simple file copy off the device.
- Document a "lost my phone" procedure: rotate the token from the laptop, done.

## Known limitations (be honest about these)

- `pyautogui`-based automation is "blind" — it doesn't verify the on-screen effect of an action before moving on. This is a functional risk more than a security one, but it means a misfired action can go further than intended before anything notices. **Track B5 decision: blind automation stays unimplemented on purpose.** Real keystroke injection without focus verification ships misfires (a `type_text` aimed at one window lands in whatever happens to be focused), so only the safety scaffold landed: read-only `focus_check` (ctypes Win32 title polling, Windows-only, no new deps), laptop-consent reuse via the ops queue, and `type_text`/`press_keys` as consent-gated STUBS that pause for approval and then raise an honest "desktop input lands in a later track" error (never a silent no-op or fake success). No `pyautogui`/`pygetwindow` dependency is added until focus verification + consent + per-op confirmation all hold together.
- MJPEG streaming, even authenticated, shows *everything* on screen — there's no selective redaction of, say, a password manager window. Treat "near mode" as "this person can see everything on my screen," not as a scoped permission.
- This threat model assumes a reasonably trusted home/personal network. It is not hardened for hostile or shared networks (student housing Wi-Fi, cafés) — don't run it there without the VPN/tunnel approach above.
- v0.1.0 notifications are in-app SSE SnackBars only — no FCM/background push is implemented, so v0.1.0 is local-first-when-the-app-is-open with zero cloud dependency. If FCM background push is ever added, that configuration becomes local-first-when-open only, not zero-cloud-dependency, because background push routes through Google's FCM infrastructure.
- Bluetooth RSSI proximity is a UX convenience only (fewer taps when near), not a security boundary — it is trivially spoofable. The phone fetches `rssi_near_threshold` via authenticated `GET /proximity` (readable in FAR mode on purpose; mode + threshold only, never the token), applies it locally to its BLE readings (stale→null, fail-closed), and sends self-attested `X-RSSI` whose ONLY server-side use is the near/far gate in `require_near` (fail-closed to far; never branches auth identity, lockout, throttling, or consent). LAN + token auth remain the actual access control. `POST /proximity/threshold` tunes that same UX-only value server-side and therefore still requires full auth (token + near): an unauthenticated config-write is a DoS/annoyance vector even when the value itself is not a security boundary.

## Incident response (the short version)

If you suspect a token leak or unauthorized access: rotate the token immediately from the laptop with `python scripts/rotate_token.py` (laptop-only CLI — regenerates the token via `server.auth` helpers, persists it atomically, and prints it once for re-pairing; the old token stops working immediately). Track E1 BLOCKER-01: rotation takes effect on the live server within one request (no restart) — the running server re-stats `security.yaml` on every auth check and reloads on mtime change, clearing in-memory lockouts. Check `logs/events.jsonl` for anything you didn't initiate, and if the laptop itself might be compromised, treat this as a full-system incident, not an Everyday Buddy–specific one.
