# Config reference

Nothing security- or behavior-relevant should be hardcoded in Python or Dart — it lives in `config/*.yaml` so it can be reviewed, versioned, and changed without touching code. See `SECURITY.md` for why the tools.yaml allowlist/denylist model matters.

## `config/models.yaml`

```yaml
ollama:
  host: "http://localhost:11434"
  dev_model: "qwen2.5:3b"      # fast iteration during development
  target_model: "llama3.1:8b"  # default for normal use
  fallback_model: "qwen2.5:3b" # used if target_model isn't pulled yet
```

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
  token_rotation_days: 30
  max_failed_attempts: 5
  lockout_minutes: 15
  idle_timeout_minutes: 60
tls:
  cert_path: "certs/dev-cert.pem"
  key_path: "certs/dev-key.pem"
proximity:
  mode: "lan_only"               # "lan_only" or "lan_plus_bluetooth"
  rssi_near_threshold: -60        # dBm; adjust after testing your own devices
  fail_mode: "far"                # what to default to if the signal can't be read — never "near"
network:
  bind_host: "0.0.0.0"           # bound to LAN interface only; do not port-forward
  bind_port: 8443
  rate_limit_per_minute: 60
```

## `config/tools.yaml` vs `config/security.yaml` — which is which

- `tools.yaml` = what the **agent** is allowed to do (shell, files, web)
- `security.yaml` = who is allowed to **reach** the agent at all (auth, TLS, proximity)

Both matter; neither substitutes for the other. A perfect allowlist doesn't help if auth is broken, and perfect auth doesn't help if the allowlist lets the agent run `rm -rf`.
