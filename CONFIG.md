# Config reference

Nothing security- or behavior-relevant should be hardcoded in Python or Dart — it lives in `config/*.yaml` so it can be reviewed, versioned, and changed without touching code. See `SECURITY.md` for why the tools.yaml allowlist/denylist model matters.

## `config/models.yaml`

```yaml
ollama:
  host: "http://localhost:11434"
  dev_model: "qwen2.5:3b"      # fast iteration during development
  target_model: "llama3.1:8b"  # default for text/API requests (quality)
  fallback_model: "qwen2.5:3b" # used if target_model isn't pulled yet
  voice_model: "qwen2.5:3b"    # default for voice-loop requests (latency over quality)
```

**Model routing rule:** `orchestrator.run(..., source="voice")` (from
`voice/voice_loop.py`) prefers `voice_model` first; `source="text"` (default,
from `POST /command`) prefers `target_model` first. This is deliberate
latency-vs-quality routing — not error fallback. Unpulled models fall through
to the next candidate; nothing ever fails on a missing tag.

```yaml
wake:
  stand_in: "alexa"                  # openWakeWord pre-trained name until maxy.onnx exists
  custom_model: "voice/models/maxy.onnx"
  threshold: 0.5                     # detection score cutoff; lower = more sensitive
```

**Wake-word rule:** `voice/wake.py::resolve_wake_models()` loads
`custom_model` when that file exists, else the `stand_in`. Training
procedure: `voice/models/README.md`. Threshold is read from here —
never hardcoded in code.

## `config/tools.yaml`

```yaml
shell:
  allowlist:
    - "git *"
    - "python -m pytest*"
    - "ls *"
    - "cat *"
  denylist:               # checked first, always wins over allowlist
    - "rm -rf*"
    - "*format*"
    - "dd *"
    - "mkfs*"
    - ":(){ :|:& };:"     # fork bomb
files:
  workspace_root: "~/buddy-workspace"
  allow_outside_workspace: false
web_search:
  backend: "duckduckgo"   # or "searxng"
  searxng_url: ""          # required if backend is searxng
agent_limits:
  max_plan_steps: 20
  max_recursion_depth: 2
  tool_timeout_seconds: 30
```

**Rule:** the denylist is checked before the allowlist and always wins, even if a command would otherwise match an allowlist pattern. See `SECURITY.md` → Tool sandboxing.

## `config/apps.yaml`

Registry of GUI apps the agent may launch via the `launch_app` tool (phone command like "open notepad"). This is the ONLY source of launcher strings — raw LLM output never reaches `launch_app` (SECURITY.md rule 4).

```yaml
apps:
  notepad:
    display: Notepad
    launcher: C:\windows\system32\notepad.exe
```

`key` is the stable id the planner resolves (also matched against `display`, case-insensitive). `launcher` must be an absolute `.exe` path; the tool refuses relative paths, non-existent files, and any shell metacharacters in the exe or args (via `shell.launch_detached`). Arguments are not supported — complex invocations belong in the `tools.yaml` shell allowlist, not here.

## `config/security.yaml`

**Gitignored.** Ship `config/security.yaml.example` with placeholder values instead.

```yaml
auth:
  token: ""                     # generated on first run, never committed
  consent_approval_secret: ""   # Track A3 (BREAKING): 64-hex laptop-only secret, generated on first run via server.auth.generate_approval_secret (secrets.token_hex(32)); approve/deny require loopback OR X-Buddy-Approval matching this — phone-token-only gets 403 approval_forbidden; revoke stays phone-gated
  token_rotation_days: 30       # reserved, NOT enforced — the hard ceiling is token_absolute_max_age_days
  token_absolute_max_age_days: 30  # hard ceiling from issuance, regardless of activity; forces re-pairing
  # issued_at: ""               # runtime-managed (ISO-8601 UTC, written on first run + rotate); missing/naive = expired
  max_failed_attempts: 5
  lockout_minutes: 15
  idle_timeout_minutes: 60
streams:                        # Track A3: read via load_streams_config with current defaults; ConsentManager takes them as constructor args
  target_fps: 2.0               # idle MJPEG frame rate
  max_consecutive_failures: 10  # then stop the stream instead of spinning
  pending_ttl_seconds: 300      # unactioned consent request TTL
  grant_ttl_seconds: 900        # approved grant TTL (15 min)
  max_consent_records: 256      # hard cap on consent records
tls:                            # consumed by scripts/serve.ps1 + gen_cert (paths), not by server/ loaders
  cert_path: "certs/dev-cert.pem"
  key_path: "certs/dev-key.pem"
proximity:
  mode: "lan_only"               # "lan_only" or "lan_plus_bluetooth"
  rssi_near_threshold: -60        # dBm; adjust after testing your own devices
  fail_mode: "far"                # what to default to if the signal can't be read — never "near"
network:
  bind_host: "0.0.0.0"           # bound to LAN interface only; do not port-forward
  bind_port: 8443                # NOTE: scripts/serve.ps1 currently hardcodes host/port — edit there, not just here
  rate_limit_per_minute: 60  # enforced per client IP by middleware in server/main.py (429 rate_limited)
```

## `config/tools.yaml` vs `config/security.yaml` — which is which

- `tools.yaml` = what the **agent** is allowed to do (shell, files, web)
- `security.yaml` = who is allowed to **reach** the agent at all (auth, TLS, proximity)

Both matter; neither substitutes for the other. A perfect allowlist doesn't help if auth is broken, and perfect auth doesn't help if the allowlist lets the agent run `rm -rf`.
