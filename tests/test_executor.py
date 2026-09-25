"""Tests for buddy_core/agents/executor.py + coder.py — scope must actually hold."""

import pytest

from buddy_core.agents.coder import CODE_VERBS, resolve_code_target
from buddy_core.agents.executor import EXECUTOR_TOOLS, execute_plan
from buddy_core.agents.planner import (
    Plan,
    PlanRejected,
    ToolCall,
    build_code_plan,
    validate_plan,
)
from buddy_core.config import AgentLimits, FilesConfig, ToolsConfig

LIMITS = AgentLimits(max_plan_steps=3, max_recursion_depth=1, tool_timeout_seconds=5)


def _tools(tmp_path) -> ToolsConfig:
    from buddy_core.config import load_tools_config

    cfg = load_tools_config()  # real allowlist/denylist — executor must honor them
    cfg.files = FilesConfig(workspace_root=str(tmp_path / "ws"), allow_outside_workspace=False)
    return cfg


def _emit(events: list):
    def _record(event_type: str, payload: dict) -> None:
        events.append((event_type, payload))

    return _record


def test_executor_scope_is_shell_plus_files() -> None:
    assert EXECUTOR_TOOLS == {"shell", "read_file", "write_file", "list_dir"}


def test_write_file_inside_workspace(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(steps=[ToolCall("write_file", {"path": "notes/hello.md", "content": "# hi"})])
    events: list = []
    result = execute_plan(plan, tools, "t1", _emit(events))
    assert result.ok
    assert result.steps_taken == 1
    assert (tmp_path / "ws" / "notes" / "hello.md").read_text() == "# hi"
    assert events[0][0] == "tool_call"
    assert events[0][1]["tool"] == "write_file"


def test_traversal_path_denied_fail_closed(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(steps=[ToolCall("write_file", {"path": "../evil.txt", "content": "x"})])
    result = execute_plan(plan, tools, "t2", _emit([]))
    assert not result.ok
    assert "workspace" in result.output.lower() or "denied" in result.output.lower()
    assert not (tmp_path / "evil.txt").exists()


def test_shell_allowlist_checked(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "git --version"})])
    result = execute_plan(plan, tools, "t3", _emit([]))
    assert result.ok  # allowlisted command runs
    assert "git version" in result.output.lower()


def test_shell_denylist_blocked(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(steps=[ToolCall("shell", {"command": "rm -rf /tmp/whatever"})])
    result = execute_plan(plan, tools, "t4", _emit([]))
    assert not result.ok
    assert "enylist" in result.output or "locked" in result.output.lower()


def test_unknown_tool_rejected_before_execution(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(steps=[ToolCall("launch_app", {"app_key": "notepad"})])
    validate_plan(plan, tools.agent_limits)  # planner allows it globally...
    result = execute_plan(plan, tools, "t5", _emit([]))
    assert not result.ok  # ...but the executor refuses it (scope)
    assert "outside executor scope" in result.output


def test_malformed_args_fail_closed(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(steps=[ToolCall("write_file", {"path": "a.txt"})])  # no content
    result = execute_plan(plan, tools, "t6", _emit([]))
    assert not result.ok
    assert "content" in result.output


def test_fail_fast_stops_after_error(tmp_path) -> None:
    tools = _tools(tmp_path)
    plan = Plan(
        steps=[
            ToolCall("write_file", {"path": "../nope.txt", "content": "x"}),
            ToolCall("write_file", {"path": "never.txt", "content": "y"}),
        ]
    )
    events: list = []
    result = execute_plan(plan, tools, "t7", _emit(events))
    assert not result.ok
    assert result.steps_taken == 0
    assert not (tmp_path / "ws" / "never.txt").exists()
    assert len([e for e in events if e[0] == "tool_call"]) == 1  # second step never ran


def test_build_code_plan_uses_known_tool() -> None:
    plan = build_code_plan("hello.py", "print('hi')", LIMITS)
    assert plan.steps[0].tool == "write_file"
    assert plan.steps[0].args == {"path": "hello.py", "content": "print('hi')"}


def test_resolve_code_target_explicit_filename() -> None:
    assert resolve_code_target("write hello.py that prints hi") == "hello.py"
    assert resolve_code_target("create notes/todo.md with three items") == "notes/todo.md"
    assert resolve_code_target("save report.JSON summarized") == "report.JSON"


def test_resolve_code_target_no_filename_is_none() -> None:
    assert resolve_code_target("write a poem about the sea") is None
    assert resolve_code_target("hello") is None
    assert resolve_code_target("research local LLMs") is None
    assert resolve_code_target("open notepad") is None


def test_code_verbs_cover_write_create_save() -> None:
    assert set(CODE_VERBS) >= {"write", "create", "save"}


def test_rejected_plan_never_executes(tmp_path) -> None:
    tools = _tools(tmp_path)
    tools.agent_limits = LIMITS
    too_long = Plan(steps=[ToolCall("list_dir", {"path": "."}) for _ in range(9)])
    with pytest.raises(PlanRejected):
        validate_plan(too_long, LIMITS)
    result = execute_plan(too_long, tools, "t8", _emit([]))
    assert not result.ok
    assert "Plan rejected" in result.output
