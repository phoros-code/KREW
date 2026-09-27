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

import json
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from buddy_core.agents.planner import Plan, validate_plan
from buddy_core.config import ToolsConfig
from buddy_core.tools import files, shell

import hashlib

# Executor scope per ARCHITECTURE.md — research tools stay in the
# orchestrator's research flow; the executor only does shell + files +
# the Track B5 browser/focus steps (browser_act always pauses for laptop
# consent first; focus_check is a read-only poll).
EXECUTOR_TOOLS = frozenset({"shell", "read_file", "write_file", "list_dir", "browser_act", "focus_check"})

# Track B3 — authoring scope per agent category (who may ORIGINATE which
# tool in a plan). EXECUTOR_TOOLS above is the RUNTIME scope of
# execute_plan: the single shell/files execution point, which also runs
# coder-originated file steps (see orchestrator._run_code). `planner` owns
# no tools (it only emits plans); launch/list_app and delegate are routed
# outside execute_plan (orchestrator launch/list flows; delegate refused).
# Track B5: browser_act is research-adjacent (researcher originates it);
# focus_check is executor-originated (read-only). type_text/press_keys are
# in NO scope — desktop input lands in a later track, so validate_plan
# rejects them as unknown tools and they can never originate anywhere.
AGENT_TOOL_SCOPES: dict[str, frozenset[str]] = {
    "coder": frozenset({"write_file", "read_file", "list_dir"}),
    "executor": frozenset({"shell", "focus_check"}),
    "researcher": frozenset({"web_search", "fetch_page", "browser_act"}),
    "planner": frozenset(),
}


def scope_allows(category: str, tool: str) -> bool:
    """True when ``category`` may originate ``tool``. Unknown categories deny."""
    return tool in AGENT_TOOL_SCOPES.get(category, frozenset())


# Track B3 — destructive-op consent. A step that WOULD be destructive pauses
# here instead of executing: without laptop approval the run fails closed
# with CONSENT_NEEDED_PREFIX (plus a redacted reason — never command/file
# text). Approval authorizes the destructive aspect WITHIN policy bounds:
# it never expands the shell allowlist — a non-allowlisted command stays
# denied even when approved (SECURITY.md: allowlist is the primary model).
# The overwrite path is the ask-me flow approval unlocks.
CONSENT_NEEDED_PREFIX = "Plan rejected: destructive step needs laptop consent (B3 consent queue)"


class ConsentRequired(RuntimeError):
    """Raised when a destructive step lacks laptop approval (fail-closed pause)."""


# In-process approval callback, set per-run by the orchestrator from server
# context (POST /ops/* queue). Receives the op record
# {"tool", "args" (redacted), "sha", "reason"} and returns approved-or-not.
# None (default — voice loop, CLI, tests) means no approvals exist.
OpConsentChecker = Callable[[dict[str, Any]], bool]

# Bounded laptop-approval wait (Track B3): the orchestrator polls the ops
# queue this long for an approve, then fails closed. Monkeypatchable in
# tests (small values keep the timeout test fast without sleeping 60s).
OPS_CONSENT_WAIT_SECONDS = 60.0
OPS_CONSENT_POLL_INTERVAL = 0.5


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

    Replaces ``args["content"]`` (write_file), ``args["command"]``
    (shell), and ``args["text"]`` (browser_act fill text / automation
    stubs — typed form/keystroke bodies that can carry passwords) string
    bodies with ``{"length": N, "sha256": "…"}``. All other keys pass
    through unchanged. Always returns a NEW dict — the caller's
    original is never mutated (the plan still executes with full values;
    only the emitted event is redacted).

    ``tool`` is accepted for future per-tool rules; currently all three
    keys are redacted regardless of tool so no emit site can leak by
    mistake.
    """
    if not isinstance(args, dict):
        return {}
    redacted = dict(args)
    for key in ("content", "command", "text"):
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


def op_record_for_step(tool: str, args: dict[str, Any]) -> dict[str, Any]:
    """Build the consent identity for one destructive step.

    ``sha`` is computed over the REDACTED shape (``redact_event_args`` —
    the same shape the phone sees on SSE ``tool_call`` events), so the
    phone can recompute it from the event stream without ever seeing
    secrets, and both sides converge on one queue entry. ``args`` in the
    record is the redacted copy for the same reason — full values stay in
    the plan, never in the consent path.
    """
    redacted = redact_event_args(tool, args if isinstance(args, dict) else {})
    canonical = json.dumps({"tool": tool, "args": redacted}, sort_keys=True, default=str)
    sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return {"tool": tool, "args": redacted, "sha": sha}


def _shell_denial_reason(command: str, shell_cfg) -> str | None:
    """Return the (redacted-safe) denial reason, or None when allowlisted."""
    try:
        shell.check_allowed(command, shell_cfg)
    except shell.ShellDenied as exc:
        return str(exc)  # redacted descriptor only (length+sha256, Track A2)
    return None


def _is_overwrite(path: str, files_cfg) -> bool:
    """True when a write would clobber an existing workspace path.

    Jail escapes return False — they are rejected anyway at execution
    (no consent hook; the write never happens). Symlink escapes resolve
    the same way as execution, so the check agrees with the write.
    """
    try:
        target = files._resolve_within_workspace(path, files_cfg)
    except Exception:
        return False
    try:
        return target.exists()
    except OSError:
        return False


def _require_op_consent(
    tool: str, args: dict[str, Any], reason: str, consent_checker: OpConsentChecker | None
) -> None:
    """Pause-or-proceed gate for destructive steps. Raises ConsentRequired."""
    record = op_record_for_step(tool, args)
    record["reason"] = reason
    approved = False
    if consent_checker is not None:
        try:
            approved = bool(consent_checker(record))
        except Exception:
            approved = False  # fail closed on checker errors
    if not approved:
        raise ConsentRequired(f"{CONSENT_NEEDED_PREFIX} — {reason}")


def _run_step(
    tool: str,
    args: dict[str, Any],
    tools_cfg: ToolsConfig,
    consent_checker: OpConsentChecker | None = None,
) -> str:
    """Dispatch one validated step. Raises on any failure (fail-fast)."""
    if tool == "shell":
        _require_args(args, "command")
        denial = _shell_denial_reason(args["command"], tools_cfg.shell)
        if denial is not None:
            # Non-allowlisted (or denylisted, or metachar) shell pauses for
            # laptop consent. Approval does NOT bypass shell.run's own
            # allowlist check below — defense in depth (SECURITY.md).
            _require_op_consent(tool, args, f"shell blocked: {denial}", consent_checker)
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
        if _is_overwrite(args["path"], tools_cfg.files):
            _require_op_consent(
                tool,
                args,
                "write_file would overwrite an existing workspace file",
                consent_checker,
            )
        target = files.write_text(args["path"], args["content"], tools_cfg.files)
        return f"Wrote {target}"
    if tool == "list_dir":
        path = args.get("path", ".")
        if not isinstance(path, str) or not path:
            raise ValueError("list_dir requires a string 'path' arg")
        names = files.list_dir(path, tools_cfg.files)
        return "\n".join(names) if names else "(empty)"
    if tool == "browser_act":
        # Track B5: DESTRUCTIVE-CLASS — the pause lives INSIDE browser_act
        # (single pause, single op identity: the tool pauses with its own
        # canonical args, so no executor-side pre-pause that could double
        # the approval round). Approval authorizes within policy bounds
        # only: the SSRF guard + domain allowlist + post-navigation
        # re-check still apply after approval.
        from buddy_core.tools import browser as _browser

        action = args.get("action")
        url = args.get("url")
        if not isinstance(action, str) or action not in _browser.BROWSER_ACTIONS:
            raise ValueError(
                f"browser_act 'action' must be one of {sorted(_browser.BROWSER_ACTIONS)}"
            )
        if not isinstance(url, str) or not url.strip():
            raise ValueError("browser_act requires a non-empty string 'url' arg")
        return _browser.browser_act(
            action,
            url,
            getattr(tools_cfg, "browser", _browser.BrowserConfig()),
            selector=args.get("selector"),
            text=args.get("text"),
            consent_checker=consent_checker,
        )
    if tool == "focus_check":
        # Track B5: read-only window-title poll — observes, never acts, so
        # no consent hook. Shape-checked here (defense in depth with the
        # planner shape check); platform gating lives in the tool.
        from buddy_core.tools import automation as _automation

        needle = args.get("title_substring")
        if not isinstance(needle, str) or not needle.strip():
            raise ValueError("focus_check requires a non-empty string 'title_substring' arg")
        found = _automation.focus_check(needle)
        return f"Window matching {needle!r}: {'found' if found else 'not found'}"
    raise ValueError(f"Tool {tool!r} is outside executor scope")


def execute_plan(
    plan: Plan,
    tools_cfg: ToolsConfig,
    task_id: str,
    emit: Callable[[str, dict[str, Any]], None],
    consent_checker: OpConsentChecker | None = None,
) -> ExecutorResult:
    """Execute a validated plan step by step. Never raises — returns a result.

    ``consent_checker`` (Track B3, extended Track B5): in-process
    laptop-approval callback for destructive steps (non-allowlisted shell,
    overwriting writes, EVERY browser_act call). None means no approvals
    exist — destructive steps pause fail-closed.
    """
    try:
        validate_plan(plan, tools_cfg.agent_limits)
    except Exception as exc:
        return ExecutorResult(ok=False, output=f"Plan rejected: {exc}")
    transcript: list[dict[str, Any]] = []
    steps_taken = 0
    for step in plan.steps:
        if step.tool == "delegate":
            # Track B1: delegate is schema-ready (planner allows it, depth
            # caps apply) but execution-gated — multi-agent delegation
            # executes in a later track (post-B3). Message unchanged.
            msg = "Plan rejected: delegation lands in B3 — delegate steps are schema-ready but execution-gated"
            transcript.append({"tool": step.tool, "ok": False, "error": msg})
            return ExecutorResult(ok=False, output=msg, steps_taken=steps_taken, transcript=transcript)
        if step.tool not in EXECUTOR_TOOLS:
            msg = f"Tool {step.tool!r} is outside executor scope — stopping"
            transcript.append({"tool": step.tool, "ok": False, "error": msg})
            return ExecutorResult(ok=False, output=msg, steps_taken=steps_taken, transcript=transcript)
        emit("tool_call", {"task_id": task_id, "tool": step.tool, "args": redact_event_args(step.tool, step.args)})
        try:
            out = _run_step(step.tool, step.args, tools_cfg, consent_checker)
        except ConsentRequired as exc:
            # Fail-closed pause (Track B3): no retry, no partial execution
            # past this step — the laptop approves via POST /ops/* and the
            # caller re-runs the plan.
            err = str(exc)
            transcript.append({"tool": step.tool, "ok": False, "error": err})
            return ExecutorResult(ok=False, output=err, steps_taken=steps_taken, transcript=transcript)
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


# --- Track B3: sha-indexed destructive-op consent queue --------------------
# The queue reuses the server's ConsentManager class (third instance,
# `ops_consent`, own TTLs from the `ops:` config block). Both the server's
# POST /ops/consent and the orchestrator's approval poll go through these
# helpers so one sha maps to one queue entry: creation is idempotent while
# pending/approved, and a decided (denied/revoked/expired) entry is replaced
# by a fresh request. The index lives ON the manager object
# (`ops_sha_index: {sha: {"id", "op"}}`) so server and orchestrator share
# one source of truth without globals. Managers are duck-typed
# (start_consent_request/status_of) so tests use fakes, no phone needed.


def _ops_index(manager: object) -> dict:
    idx = getattr(manager, "ops_sha_index", None)
    if not isinstance(idx, dict):
        idx = {}
        try:
            setattr(manager, "ops_sha_index", idx)
        except Exception:
            pass
    return idx


def ops_request_for_sha(manager: object, sha: str, op: object) -> str:
    """Return the queue's consent_id for ``sha``, creating it if needed."""
    idx = _ops_index(manager)
    entry = idx.get(sha)
    if isinstance(entry, dict):
        cid = entry.get("id")
        if isinstance(cid, str) and cid:
            try:
                status = manager.status_of(cid)  # type: ignore[attr-defined]
            except Exception:
                status = None
            if status == "pending" or status == "approved":
                return cid
    cid = manager.start_consent_request()  # type: ignore[attr-defined]
    try:
        idx[sha] = {"id": cid, "op": str(op)}
    except Exception:
        pass
    return cid


def ops_poll_for_sha(
    manager: object,
    sha: str,
    op: object,
    timeout_seconds: float | None = None,
    poll_interval: float | None = None,
    sleep: Callable[[float], None] | None = None,
) -> bool:
    """Poll the queue for laptop approval of ``sha``. Fail-closed bool.

    Returns True only on APPROVED. DENIED/REVOKED/expired-or-unknown return
    False immediately (no wait — the decision is final); PENDING waits up
    to ``timeout_seconds`` (default OPS_CONSENT_WAIT_SECONDS, ~60s) then
    returns False. Any manager error returns False.
    """
    if timeout_seconds is None:
        timeout_seconds = OPS_CONSENT_WAIT_SECONDS
    if poll_interval is None:
        poll_interval = OPS_CONSENT_POLL_INTERVAL
    if sleep is None:
        sleep = time.sleep
    try:
        cid = ops_request_for_sha(manager, sha, op)
    except Exception:
        return False
    try:
        timeout = max(0.0, float(timeout_seconds))
    except (TypeError, ValueError):
        timeout = OPS_CONSENT_WAIT_SECONDS
    try:
        interval = max(0.0, float(poll_interval))
    except (TypeError, ValueError):
        interval = OPS_CONSENT_POLL_INTERVAL
    deadline = time.monotonic() + timeout
    while True:
        try:
            status = manager.status_of(cid)  # type: ignore[attr-defined]
        except Exception:
            return False
        if status == "approved":
            return True
        if status == "denied" or status == "revoked" or status is None:
            return False
        if time.monotonic() >= deadline:
            return False
        try:
            sleep(min(interval, max(0.0, deadline - time.monotonic())) if interval else 0.0)
        except Exception:
            return False
