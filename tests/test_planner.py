"""Tests for buddy_core/agents/planner.py — caps must actually fire."""

import pytest

from buddy_core.agents.planner import (
    KNOWN_TOOLS,
    Plan,
    PlanRejected,
    ToolCall,
    build_research_plan,
    validate_plan,
)
from buddy_core.config import AgentLimits

LIMITS = AgentLimits(max_plan_steps=3, max_recursion_depth=1, tool_timeout_seconds=5)


def test_valid_plan_passes() -> None:
    validate_plan(Plan(steps=[ToolCall("web_search", {"query": "x"})]), LIMITS)


def test_step_cap_enforced() -> None:
    plan = Plan(steps=[ToolCall("web_search", {"query": str(i)}) for i in range(4)])
    with pytest.raises(PlanRejected):
        validate_plan(plan, LIMITS)


def test_recursion_cap_enforced() -> None:
    with pytest.raises(PlanRejected):
        validate_plan(Plan(steps=[ToolCall("web_search", {})], depth=2), LIMITS)


def test_unknown_tool_rejected() -> None:
    with pytest.raises(PlanRejected):
        validate_plan(Plan(steps=[ToolCall("rm_rf_everything", {})]), LIMITS)


def test_research_plan_uses_known_tools_only() -> None:
    plan = build_research_plan("research local LLMs", AgentLimits())
    assert plan.steps
    assert all(s.tool in KNOWN_TOOLS for s in plan.steps)
