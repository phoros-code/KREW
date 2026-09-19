"""PlannerAgent — the ONLY thing that ever reaches a tool is a typed plan.

Raw LLM text is never string-interpolated into a shell command or file path
(CLAUDE.md rule 4). Every plan is validated against agent_limits from
config/tools.yaml: max steps + max recursion depth (TESTING.md).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from buddy_core.config import AgentLimits

# Tool categories per ARCHITECTURE.md — an agent never calls outside its scope.
KNOWN_TOOLS = frozenset({"web_search", "fetch_page", "shell", "read_file", "write_file", "list_dir"})


@dataclass
class ToolCall:
    tool: str
    args: dict[str, Any] = field(default_factory=dict)


@dataclass
class Plan:
    steps: list[ToolCall] = field(default_factory=list)
    depth: int = 0  # delegation depth; 0 = top-level plan


class PlanRejected(ValueError):
    """Raised when a plan violates size, depth, or tool-scope caps."""


def validate_plan(plan: Plan, limits: AgentLimits) -> None:
    """Enforce caps. Raises PlanRejected — caps must actually fire (TESTING.md)."""
    if len(plan.steps) > limits.max_plan_steps:
        raise PlanRejected(
            f"Plan has {len(plan.steps)} steps, max is {limits.max_plan_steps}"
        )
    if plan.depth > limits.max_recursion_depth:
        raise PlanRejected(
            f"Plan depth {plan.depth} exceeds max {limits.max_recursion_depth}"
        )
    for step in plan.steps:
        if step.tool not in KNOWN_TOOLS:
            raise PlanRejected(f"Unknown tool {step.tool!r} — raw LLM output is never executed")


def build_research_plan(command: str, limits: AgentLimits) -> Plan:
    """Phase-0 deterministic plan: search, fetch top hits, summarize.

    The fetch/summarize steps are resolved at execution time from real
    search results — the LLM never invents URLs or commands.
    """
    plan = Plan(
        steps=[
            ToolCall("web_search", {"query": command, "max_results": 5}),
            ToolCall("fetch_page", {"max_pages": 2, "max_chars": 8000}),
        ],
        depth=0,
    )
    validate_plan(plan, limits)
    return plan
