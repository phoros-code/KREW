"""Restricted shell tool — the ONLY place ``subprocess`` is called in this repo.

Allowlist + denylist come from ``config/tools.yaml`` (CLAUDE.md rule 1).
The denylist is checked first and always wins over the allowlist (CONFIG.md).

Defense in depth:
- Built-in metacharacter block (``; && || | $ ` > <`` newlines) stops
  command chaining even if an allowlist pattern would otherwise match.
- Commands run with ``shell=False`` so there is no shell to inject into.
- Per-call timeout from ``agent_limits.tool_timeout_seconds``.
"""

from __future__ import annotations

import fnmatch
import os
import shlex
import subprocess
from dataclasses import dataclass

from buddy_core.config import ShellConfig

import hashlib

# Independent of config/tools.yaml — always blocked (SECURITY.md).
# NOTE: "&" covers both lone-& (cmd.exe chaining: `a & b`) and "&&";
# "|" likewise covers "||". "\x00" turns a would-be ValueError from
# subprocess into a clean ShellDenied. shell=False is the real barrier;
# this list is defense in depth.
_BUILTIN_DENY_CHARS = (";", "&", "&&", "||", "|", "$", "`", ">", "<", "\n", "\r", "\x00")


class ShellDenied(ValueError):
    """Raised when a command is not allowlisted or hits the denylist."""


class LaunchDenied(ShellDenied):
    """Raised for an unsafe app-launch request (bad exe, path, or args)."""

    def __init__(self, reason: str, argv: list[str]):
        super().__init__(reason)
        self.argv = argv


def _redact_descriptor(command: str) -> str:
    """Describe a blocked command without echoing it (Track A2).

    events.jsonl and SSE must never contain full command text
    (SECURITY.md) — ShellDenied messages previously embedded ``{cmd!r}``,
    which leaked the full body into task_failed error fields. Now only
    length + sha256 are emitted; the raw text never leaves this function.
    """
    raw = command.encode("utf-8", errors="replace")
    return f"length={len(command)} sha256={hashlib.sha256(raw).hexdigest()}"


def _matches(command: str, patterns: list[str], case_insensitive: bool = False) -> str | None:
    """Return the first matching pattern, or None."""
    text = command.lower() if case_insensitive else command
    for pat in patterns:
        p = pat.lower() if case_insensitive else pat
        if fnmatch.fnmatchcase(text, p):
            return pat
    return None


def check_allowed(command: str, config: ShellConfig) -> None:
    """Validate a command. Raises ShellDenied with the reason if blocked."""
    cmd = command.strip()
    if not cmd:
        raise ShellDenied("Empty command")
    if _matches(cmd, config.denylist, case_insensitive=True):
        raise ShellDenied(f"Blocked by denylist ({_redact_descriptor(cmd)})")
    if any(c in cmd for c in _BUILTIN_DENY_CHARS):
        raise ShellDenied(f"Blocked: shell metacharacters not allowed ({_redact_descriptor(cmd)})")
    if not _matches(cmd, config.allowlist):
        raise ShellDenied(f"Not in allowlist ({_redact_descriptor(cmd)})")


def is_allowed(command: str, config: ShellConfig) -> bool:
    """Non-raising form of check_allowed."""
    try:
        check_allowed(command, config)
    except ShellDenied:
        return False
    return True


@dataclass
class ShellResult:
    ok: bool
    returncode: int
    stdout: str
    stderr: str


def run(command: str, config: ShellConfig, timeout_seconds: int = 30) -> ShellResult:
    """Run an allowlisted command, capturing output. Raises ShellDenied if blocked."""
    check_allowed(command, config)
    argv = shlex.split(command, posix=(os.name != "nt"))
    if os.name == "nt":
        # shlex with posix=False keeps quote chars; strip one matching pair
        # so `python -c "print('hi')"` reaches the interpreter unquoted.
        argv = [
            a[1:-1] if len(a) >= 2 and a[0] == a[-1] and a[0] in ("'", '"') else a
            for a in argv
        ]
    try:
        proc = subprocess.run(  # noqa: S603 — allowlist+denylist validated above; sole call site
            argv,
            shell=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        return ShellResult(ok=False, returncode=124, stdout=exc.stdout or "", stderr=f"Timed out after {timeout_seconds}s")
    except FileNotFoundError:
        return ShellResult(ok=False, returncode=127, stdout="", stderr=f"Executable not found: {argv[0]!r}")
    return ShellResult(
        ok=proc.returncode == 0,
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
    )


def launch_detached(exe_path: str, args: list[str] | None = None) -> ShellResult:
    """Launch a GUI app detached from the agent (fire-and-forget).

    Distinct from ``run``: this does NOT wait for the process to finish —
    GUI apps like Notepad must return control to the orchestrator
    immediately. The caller is ``buddy_core/tools/launch_app.py``, which only
    ever passes an exe path from ``config/apps.yaml`` (never LLM text).

    Slightly weaker than ``run``: args are passed as a list (no shell
    parsing), but ``_BUILTIN_DENY_CHARS`` is still enforced on every arg.
    The exe must be an absolute, existing path.
    """
    argv = [exe_path, *(args or [])]
    for token in argv:
        if any(ch in token for ch in _BUILTIN_DENY_CHARS):
            raise LaunchDenied(f"Blocked: shell metacharacters not allowed ({_redact_descriptor(token)})", argv)
    if not os.path.isabs(exe_path):
        raise LaunchDenied(f"Launcher must be an absolute path: {exe_path!r}", argv)
    if not os.path.isfile(exe_path):
        raise LaunchDenied(f"Launcher does not exist: {exe_path!r}", argv)

    creationflags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    try:
        proc = subprocess.Popen(  # noqa: S603 — validated above; detached, no shell
            argv,
            shell=False,
            close_fds=True,
            creationflags=creationflags,
        )
    except OSError as exc:
        return ShellResult(ok=False, returncode=127, stdout="", stderr=f"Failed to launch {exe_path!r}: {exc}")
    return ShellResult(ok=True, returncode=0, stdout=f"Started PID {proc.pid}", stderr="")
