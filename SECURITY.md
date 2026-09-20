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
- **Timeouts and resource locks** per tool call, so one runaway process can't hang or starve the rest of the system.

## Consent

Explicit, un-skippable prompts before:
- Starting a screen share
- Starting webcam access
- Any file operation outside a normal read/write in the workspace (delete, overwrite outside workspace, anything the denylist would otherwise catch)
- Any shell command not already in the allowlist, if you choose to support an "ask me" fallback rather than a hard block

## Secrets & data handling

- **No secrets in source control.** `config/security.yaml` (tokens, cert paths) is gitignored; ship a `security.yaml.example` instead.
- **Inference, agents, data, and telemetry stay local.** No telemetry, no analytics calls, no crash reporting that phones home by default — if you ever add any, it must be opt-in and disclosed in `README.md`. Optional FCM background push is the one exception — see Known limitations.
- **Screen/webcam frames are not persisted** beyond what's needed to stream them live — don't accidentally build a rolling video archive of your own screen.
- **Event logs (`logs/events.jsonl`)** should log what the agent did, not raw sensitive payloads — avoid dumping full file contents or screen frames into the log.

## Dependency hygiene

- Pin versions in `requirements.txt` / `pubspec.yaml` — don't float on `latest` for anything with shell/file access.
- Run `pip-audit` (Python) and equivalent tooling for the Flutter side periodically, especially before a release.
- Review dependency updates to `buddy_core/tools/` and `server/auth.py` more carefully than anywhere else in the repo — these are the modules where a supply-chain issue has the most impact.

## Physical device security

- Require the phone's own lock screen to use the companion app (don't add a bypass).
- Token stored in secure hardware-backed storage, not recoverable by a simple file copy off the device.
- Document a "lost my phone" procedure: rotate the token from the laptop, done.

## Known limitations (be honest about these)

- `pyautogui`-based automation is "blind" — it doesn't verify the on-screen effect of an action before moving on. This is a functional risk more than a security one, but it means a misfired action can go further than intended before anything notices.
- MJPEG streaming, even authenticated, shows *everything* on screen — there's no selective redaction of, say, a password manager window. Treat "near mode" as "this person can see everything on my screen," not as a scoped permission.
- This threat model assumes a reasonably trusted home/personal network. It is not hardened for hostile or shared networks (student housing Wi-Fi, cafés) — don't run it there without the VPN/tunnel approach above.
- v0.1.0 with in-app SSE + FCM background push is local-first-when-the-app-is-open, not zero-cloud-dependency — background push routes through Google's FCM infrastructure.
- Bluetooth RSSI proximity is a UX convenience only (fewer taps when near), not a security boundary — it is trivially spoofable. LAN + token auth remain the actual access control.

## Incident response (the short version)

If you suspect a token leak or unauthorized access: rotate the token immediately from the laptop, check `logs/events.jsonl` for anything you didn't initiate, and if the laptop itself might be compromised, treat this as a full-system incident, not an Everyday Buddy–specific one.
