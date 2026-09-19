# Everyday Buddy

A local-first, multi-agent AI assistant that runs on your laptop and is controlled from your phone. No cloud dependency, no subscription, fully open source.

Codename: `buddy-core` · License: MIT (see [`LICENSE`](./LICENSE))

---

## What's in this repo's docs

| File | What it's for | Read it when |
|---|---|---|
| [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) | The full product spec: architecture, features, tech stack, roadmap, prior art | Before you write any code |
| [`CLAUDE.md`](./CLAUDE.md) | Context file your AI coding agent reads every session | Never read by you directly — the agent uses it |
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | Module-by-module breakdown, data flow, directory layout | When implementing or reviewing a specific component |
| [`SECURITY.md`](./SECURITY.md) | Threat model and every security control this project needs | Before you implement auth, the shell tool, or the phone pairing flow |
| [`UI_UX_GUIDE.md`](./UI_UX_GUIDE.md) | What makes an app look AI-generated, and how to avoid it here | Before and during any UI work (phone app, web dashboard) |
| [`DESIGN.md`](./DESIGN.md) | The actual design contract — palette, type, spacing, banned patterns | Fed to your AI agent alongside `CLAUDE.md` for every UI-touching session |
| [`CONFIG.md`](./CONFIG.md) | What goes in `config/*.yaml` and why | When touching tool permissions or security thresholds |
| [`API.md`](./API.md) | REST/SSE/MJPEG endpoint reference | When building the control server or the phone app's network layer |
| [`TESTING.md`](./TESTING.md) | What must have automated tests vs. what needs manual/hardware testing | Before merging anything touching `tools/shell.py` or `server/auth.py` |
| [`PROMPTS.md`](./PROMPTS.md) | The full prompt library for building this with an AI coding agent, phase by phase | During every build session |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | Branch/commit conventions and the PR checklist | Before opening a PR (even to yourself) |

## Quick start

```powershell
# 1. Python 3.12 venv (CrewAI-compatible; 3.14 lacks wheels for its pins)
py -3.12 -m venv venv312; .\venv312\Scripts\python.exe -m pip install -e ".[dev]"

# 2. Models (dev + target)
ollama pull qwen2.5:3b
ollama pull llama3.1:8b

# 3. Research from the CLI (Phase 0)
.\venv312\Scripts\python.exe -m buddy_core "research local LLMs"

# 4. Dev TLS cert + control server over HTTPS (Phase 2)
.\venv312\Scripts\python.exe scripts\gen_cert.py
.\venv312\Scripts\python.exe scripts\pair_device.py   # IP + token + fingerprint for the phone
powershell -ExecutionPolicy Bypass -File scripts\serve.ps1
```

Full phased build instructions are in [`PROMPTS.md`](./PROMPTS.md).

## Project status

Track this in `CLAUDE.md`'s status section — that's the single source of truth for "what's done" since it's what your AI agent reads at the start of every session.

## License

MIT or Apache 2.0 — pick one and put it in `LICENSE` before your first public commit. Both are compatible with every dependency in [`PROJECT_SPEC.md`](./PROJECT_SPEC.md)'s tech stack.
