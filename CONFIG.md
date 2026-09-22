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

## `config/security.yaml`

**Gitignored.** Ship `config/security.yaml.example` with placeholder values instead.

```yaml
auth:
  token: ""                     # generated on first run, never committed
  token_rotation_days: 30       # reserved, NOT enforced — the hard ceiling is token_absolute_max_age_days
  token_absolute_max_age_days: 30  # hard ceiling from issuance, regardless of activity; forces re-pairing
  # issued_at: ""               # runtime-managed (ISO-8601 UTC, written on first run + rotate); missing/naive = expired
  max_failed_attempts: 5
  lockout_minutes: 15
  idle_timeout_minutes: 60
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
