"""Restricted file tool — the ONLY way agents touch the filesystem.

All access is confined to ``~/buddy-workspace`` (see ``config/tools.yaml``).
Path traversal (``../``, absolute paths, symlink escapes) is rejected.
See SECURITY.md → Tool sandboxing.
"""

from __future__ import annotations

from pathlib import Path

from buddy_core.config import FilesConfig


class FileAccessDenied(ValueError):
    """Raised when a path escapes the workspace or is otherwise forbidden."""


def resolve_workspace_root(config: FilesConfig) -> Path:
    return Path(config.workspace_root).expanduser().resolve()


def _resolve_within_workspace(rel_path: str, config: FilesConfig) -> Path:
    """Resolve a user-supplied path, guaranteeing it stays in the workspace.

    Raises FileAccessDenied on traversal, absolute-path escape, or symlink
    escape. Never string-interpolate raw LLM output — the planner passes a
    typed argument here and this function validates it (CLAUDE.md rule 4).
    """
    root = resolve_workspace_root(config)
    candidate = (root / rel_path).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        raise FileAccessDenied(f"Path escapes workspace: {rel_path!r}") from None
    return candidate


def read_text(path: str, config: FilesConfig) -> str:
    """Read a UTF-8 text file inside the workspace."""
    target = _resolve_within_workspace(path, config)
    if not target.is_file():
        raise FileNotFoundError(f"No such file in workspace: {path!r}")
    return target.read_text(encoding="utf-8")


def write_text(path: str, content: str, config: FilesConfig) -> Path:
    """Write UTF-8 text to a file inside the workspace (creates parents)."""
    target = _resolve_within_workspace(path, config)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    return target


def list_dir(path: str, config: FilesConfig) -> list[str]:
    """List names inside a workspace directory (non-recursive)."""
    target = _resolve_within_workspace(path, config)
    if not target.is_dir():
        raise NotADirectoryError(f"Not a directory in workspace: {path!r}")
    return sorted(p.name for p in target.iterdir())
