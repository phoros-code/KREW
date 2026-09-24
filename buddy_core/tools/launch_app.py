"""App-launch tool — launches a GUI app from config/apps.yaml.

CLAUDE.md rule 1: subprocess lives only in ``tools/shell.py``. This tool is
the safety boundary for *which* exe may launch: the registry in
``config/apps.yaml`` is the ONLY source of launcher strings — raw LLM output
never reaches this tool (SECURITY.md rules 3 & 4). Every launch passes
through ``shell.launch_detached``, which enforces absolute-path/exists
checks and rejects shell metacharacters.
"""

from __future__ import annotations

from dataclasses import dataclass

from buddy_core.config import AppsConfig, ToolsConfig
from buddy_core.tools.shell import launch_detached as _launch_detached


class AppNotFound(KeyError):
    """Raised when an app key is not in the config/apps.yaml registry."""


@dataclass
class LaunchResult:
    ok: bool
    message: str
    pid: int | None = None


DENY_CHARS = (";", "&", "&&", "||", "|", "$", "`", ">", "<", "\n", "\r", "\x00")


def _validate_app_key(app_key: str) -> None:
    """Allowlist-safe app key: a short, plain identifier — never a path."""
    if not app_key or not app_key.isidentifier() or len(app_key) > 40:
        raise ValueError(f"Invalid app key: {app_key!r}")
    if any(c in app_key for c in DENY_CHARS + (".", "/", "\\", ":")):
        raise ValueError(f"App key must be a plain identifier: {app_key!r}")


def list_apps(config: AppsConfig) -> list[str]:
    """Return sorted 'key — display' registry entries."""
    return [f"{key} — {entry.display}" for key, entry in sorted(config.apps.items())]


def launch(app_key: str, config: AppsConfig, tools: ToolsConfig) -> LaunchResult:
    """Launch the exe registered under ``app_key`` (fire-and-forget).

    Raises AppNotFound for an unknown key; never touches a path that did not
    originate in config/apps.yaml.
    """
    _validate_app_key(app_key)
    entry = config.apps.get(app_key)
    if entry is None:
        known = ", ".join(sorted(config.apps)) or "(none registered)"
        raise AppNotFound(f"Unknown app {app_key!r}. Registered: {known}")

    try:
        result = _launch_detached(entry.launcher.strip())
    except Exception as exc:  # noqa: BLE001 — surface as failure, never raise
        return LaunchResult(ok=False, message=f"Launch denied: {exc}")
    if not result.ok:
        return LaunchResult(ok=False, message=result.stderr or "Launch failed.")
    pid = None
    if result.stdout.startswith("Started PID "):
        try:
            pid = int(result.stdout.split()[-1])
        except ValueError:
            pid = None
    return LaunchResult(ok=True, message=result.stdout.strip() or "Launched.", pid=pid)


__all__ = ["launch", "list_apps", "LaunchResult", "AppNotFound"]