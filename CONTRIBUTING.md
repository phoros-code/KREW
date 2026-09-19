# Contributing

Lightweight conventions — this scales down fine for a solo project, but having them from day one means the repo doesn't need a cleanup pass later.

## Branches

`phase0/shell-tool`, `phase2/auth`, `fix/proximity-fail-open` — phase prefix while you're working through `PROMPTS.md`'s roadmap, `fix/` or `chore/` after v0.1.0.

## Commits

`phase0: add shell tool allowlist/denylist` style — phase or area prefix, imperative mood, no period.

## Before opening a PR (even to yourself)

- [ ] Full test suite passes, not just tests for what changed — see `TESTING.md`
- [ ] If this touches `shell.py`, `files.py`, or `auth.py`: re-read the relevant `SECURITY.md` section and confirm the change doesn't weaken it
- [ ] If this touches any screen: run `UI_UX_GUIDE.md`'s self-audit checklist and confirm `DESIGN.md`'s hard rules
- [ ] `CLAUDE.md`'s status section is up to date
- [ ] No secrets in the diff — check `config/security.yaml` specifically didn't get un-gitignored

## Code style

- Python: type hints on every public function, docstrings on every tool/agent
- Dart/Flutter: follow `DESIGN.md` for anything visual, no exceptions without updating `DESIGN.md` first
