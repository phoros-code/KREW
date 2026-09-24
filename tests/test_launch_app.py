"""Tests for buddy_core/tools/launch_app.py — registry is the only path source."""

import sys

import pytest

from buddy_core.config import AppEntry, AppsConfig, AgentLimits, ToolsConfig
from buddy_core.tools import launch_app
from buddy_core.tools.launch_app import AppNotFound, LaunchResult, launch, list_apps
from buddy_core.tools.shell import LaunchDenied, launch_detached

from buddy_core.agents.planner import (
    KNOWN_TOOLS,
    ToolCall,
    build_launch_plan,
    build_list_apps_plan,
    resolve_launch_intent,
)

LIMITS = AgentLimits(max_plan_steps=3, max_recursion_depth=1, tool_timeout_seconds=5)


def _cfg() -> AppsConfig:
    return AppsConfig(
        apps={
            "calculator": AppEntry(display="Calculator", launcher=r"C:\windows\system32\calc.exe"),
            "notepad": AppEntry(display="Notepad", launcher=r"C:\windows\system32\notepad.exe"),
        }
    )


def test_list_apps_sorted() -> None:
    entries = list_apps(_cfg())
    assert entries == ["calculator — Calculator", "notepad — Notepad"]


def test_list_apps_empty() -> None:
    assert list_apps(AppsConfig()) == []


def test_launch_unknown_app_raises() -> None:
    with pytest.raises(AppNotFound):
        launch("spotify", _cfg(), ToolsConfig())


def test_launch_denied_for_bad_path() -> None:
    cfg = AppsConfig(apps={"bad": AppEntry(display="Bad", launcher="relative.exe")})
    result = launch("bad", cfg, ToolsConfig())
    assert not result.ok
    assert "absolute" in result.message


def test_launch_detached_rejects_relative() -> None:
    with pytest.raises(LaunchDenied):
        launch_detached("calc.exe")


def test_launch_detached_rejects_metachars() -> None:
    with pytest.raises(LaunchDenied):
        launch_detached(r"C:\tmp\x.exe", args=["; rm -rf /"])


def test_launch_detached_missing_exe_fails_cleanly() -> None:
    with pytest.raises(LaunchDenied):
        launch_detached(r"C:\does\not\exist.exe")


@pytest.mark.skipif(sys.platform != "win32", reason="Windows-only launcher paths")
def test_launch_happy_path_real_exe() -> None:
    cfg = AppsConfig(apps={"whoami": AppEntry(display="Whoami", launcher=r"C:\windows\system32\whoami.exe")})
    result = launch("whoami", cfg, ToolsConfig())
    assert result.ok
    assert result.pid is not None


def test_app_key_validation_rejects_paths() -> None:
    for bad in ("./calc.exe", "a\\b", "a/b", "a:b"):
        with pytest.raises(ValueError):
            launch_app._validate_app_key(bad)


def test_build_launch_plan_uses_known_tool() -> None:
    plan = build_launch_plan("notepad", LIMITS)
    assert plan.steps == [ToolCall("launch_app", {"app_key": "notepad"})]
    assert "launch_app" in KNOWN_TOOLS


def test_build_list_apps_plan() -> None:
    plan = build_list_apps_plan(LIMITS)
    assert plan.steps[0].tool == "list_apps"
    assert "list_apps" in KNOWN_TOOLS


def test_resolve_launch_intent_matches_display_name() -> None:
    assert resolve_launch_intent("open calculator", _cfg()) == "calculator"


def test_resolve_launch_intent_matches_key_verb() -> None:
    assert resolve_launch_intent("launch notepad", _cfg()) == "notepad"


def test_resolve_launch_intent_unknown_app_is_none() -> None:
    assert resolve_launch_intent("open spotify", _cfg()) is None
    assert resolve_launch_intent("launch nothing", _cfg()) is None


def test_resolve_launch_intent_no_verb_is_none() -> None:
    assert resolve_launch_intent("calculator", _cfg()) is None
    assert resolve_launch_intent("open up notepad", _cfg()) == "notepad"