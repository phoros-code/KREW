"""ExecutorAgent — the ONLY agent that touches shell/files tools.

Takes a validated ``Plan`` (planner.validate_plan must already have passed)
and executes each step against ``buddy_core/tools``. Defense in depth:
the executor re-checks every step's tool against its own scope and its
args against a per-tool schema — an unknown tool or malformed args fails
the run closed (no partial execution past the failure).

Fail-fast: the first failing step stops the plan. The transcript records
every attempted step so the caller can report exactly what happened.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from buddy_core.agents.planner import Plan, validate_plan
from buddy_core.config import ToolsConfig
from buddy_core.tools import files, shell

import hashlib

# Executor scope per ARCHITECTURE.md — research tools stay in the
# orchestrator's research flow; the executor only does shell + files.
EXECUTOR_TOOLS = frozenset({"shell", "read_file", "write_file", "list_dir"})


def _redact_text_value(value: str) -> dict:
    """Describe a sensitive body without storing it (SECURITY.md).

    Returns ``{"length": N, "sha256": "…"}`` so the log/SSE proves *what*
    was sent (size + hash for debugging) without ever containing the full
    file contents or full command text.
    """
    raw = value.encode("utf-8", errors="replace")
    return {"length": len(value), "sha256": hashlib.sha256(raw).hexdigest()}


def redact_event_args(tool: str, args: dict[str, Any] | None) -> dict[str, Any]:
    """Redact sensitive bodies before ANY event emission (Track A2).

    Replaces ``args["content"]`` (write_file) and ``args["command"]``
    (shell) string bodies with ``{"length": N, "sha256": "…"}``. All other
    keys pass through unchanged. Always returns a NEW dict — the caller's
    original is never mutated (the plan still executes with full values;
    only the emitted event is redacted).

    ``tool`` is accepted for future per-tool rules; currently both keys
    are redacted regardless of tool so no emit site can leak by mistake.
    """
    if not isinstance(args, dict):
        return {}
    redacted = dict(args)
    for key in ("content", "command"):
        val = redacted.get(key)
        if isinstance(val, str):
            redacted[key] = _redact_text_value(val)
    return redacted


@dataclass
class ExecutorResult:
    ok: bool
    output: str
    steps_taken: int = 0
    transcript: list[dict[str, Any]] = field(default_factory=list)


def _require_args(args: dict[str, Any], *names: str) -> None:
    missing = [n for n in names if not isinstance(args.get(n), str) or not args[n]]
    if missing:
        raise ValueError(f"Missing required string args: {', '.join(missing)}")


def _run_step(tool: str, args: dict[str, Any], tools_cfg: ToolsConfig) -> str:
    """Dispatch one validated step. Raises on any failure (fail-fast)."""
    if tool == "shell":
        _require_args(args, "command")
        result = shell.run(
            args["command"],
            tools_cfg.shell,
            timeout_seconds=tools_cfg.agent_limits.tool_timeout_seconds,
        )
        if not result.ok:
            raise RuntimeError(result.stderr or f"shell exited {result.returncode}")
        return result.stdout.strip() or "(no output)"
    if tool == "read_file":
        _require_args(args, "path")
        return files.read_text(args["path"], tools_cfg.files)
    if tool == "write_file":
        _require_args(args, "path", "content")
        target = files.write_text(args["path"], args["content"], tools_cfg.files)
        return f"Wrote {target}"
    if tool == "list_dir":
        path = args.get("path", ".")
        if not isinstance(path, str) or not path:
            raise ValueError("list_dir requires a string 'path' arg")
        names = files.list_dir(path, tools_cfg.files)
        return "\n".join(names) if names else "(empty)"
    raise ValueError(f"Tool {tool!r} is outside executor scope")


def execute_plan(
    plan: Plan,
    tools_cfg: ToolsConfig,
    task_id: str,
    emit: Callable[[str, dict[str, Any]], None],
) -> ExecutorResult:
    """Execute a validated plan step by step. Never raises — returns a result."""
    try:
        validate_plan(plan, tools_cfg.agent_limits)
    except Exception as exc:
        return ExecutorResult(ok=False, output=f"Plan rejected: {exc}")
    transcript: list[dict[str, Any]] = []
    steps_taken = 0
    for step in plan.steps:
        if step.tool not in EXECUTOR_TOOLS:
            msg = f"Tool {step.tool!r} is outside executor scope — stopping"
            transcript.append({"tool": step.tool, "ok": False, "error": msg})
            return ExecutorResult(ok=False, output=msg, steps_taken=steps_taken, transcript=transcript)
        emit("tool_call", {"task_id": task_id, "tool": step.tool, "args": redact_event_args(step.tool, step.args)})
        try:
            out = _run_step(step.tool, step.args, tools_cfg)
        except Exception as exc:  # noqa: BLE001 — fail-fast, report, stop
            err = f"{type(exc).__name__}: {exc}"
            transcript.append({"tool": step.tool, "ok": False, "error": err})
            return ExecutorResult(ok=False, output=err, steps_taken=steps_taken, transcript=transcript)
        steps_taken += 1
        transcript.append({"tool": step.tool, "ok": True, "output": out[:2000]})
    outputs = [t["output"] for t in transcript if t["ok"]]
    return ExecutorResult(
        ok=True,
        output="\n".join(outputs) if outputs else "(no steps)",
        steps_taken=steps_taken,
        transcript=transcript,
    )
