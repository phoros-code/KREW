"""Track B5 (browser automation + desktop-typing safety scaffold) tests.

Covers: domain allowlist (empty denies, listed allows incl. subdomains,
private IP denies even if listed), browser_act always pausing for laptop
consent (read_text too), approve→executes with a FAKE playwright module
(never a real browser in pytest), headless+sandbox launch args, context
closed on success AND on mid-action failure, playwright-missing error,
focus_check true/false/unsupported-platform/empty, stubs
pause-then-raise-honestly (with keystroke redaction), scope matrix
updates, validate_plan shapes (+ type_text/press_keys rejected as
unknown), system-prompt schemas, and tools.yaml browser/automation
config parsing.
"""

from __future__ import annotations

import json
import sys
import types

import pytest

from buddy_core.agents.executor import (
    AGENT_TOOL_SCOPES,
    CONSENT_NEEDED_PREFIX,
    EXECUTOR_TOOLS,
    ConsentRequired,
    execute_plan,
    scope_allows,
)
from buddy_core.agents.planner import (
    KNOWN_TOOLS,
    Plan,
    PlanRejected,
    ToolCall,
    _planner_system_prompt,
    validate_plan,
)
from buddy_core.config import AgentLimits, BrowserConfig, FilesConfig
from buddy_core.tools import automation as auto_mod
from buddy_core.tools import browser as browser_mod
from buddy_core.tools.automation import AutomationNotImplemented
from buddy_core.tools.browser import (
    BROWSER_ACTIONS,
    BrowserConfig as ToolBrowserConfig,
    BrowserDenied,
    BrowserNotInstalled,
    browser_act,
    check_url,
    domain_allowed,
)

LIMITS = AgentLimits(max_plan_steps=3, max_recursion_depth=1, tool_timeout_seconds=5)

ALLOW = ToolBrowserConfig(allowed_domains=["example.com"])
DENY_ALL = ToolBrowserConfig(allowed_domains=[])


def _tools_cfg(tmp_path):
    from buddy_core.config import load_tools_config

    cfg = load_tools_config()
    cfg.files = FilesConfig(workspace_root=str(tmp_path / "ws"))
    cfg.agent_limits = LIMITS
    (tmp_path / "ws").mkdir(parents=True, exist_ok=True)
    return cfg


def _emit(events: list):
    def _record(event_type: str, payload: dict) -> None:
        events.append((event_type, payload))

    return _record


def _fake_dns(monkeypatch, *, public: bool = True):
    """Fake only DNS resolution inside the SSRF guard (scheme checks stay real)."""
    import buddy_core.tools.web_search as ws

    if public:
        monkeypatch.setattr(ws, "_resolve_public_addrs", lambda host, port: ["pinned"])
    else:

        def _deny(host, port):
            raise ValueError(
                f"Blocked host {host!r}: resolves to non-public address 192.168.1.9"
            )

        monkeypatch.setattr(ws, "_resolve_public_addrs", _deny)


# --- fake playwright (never launch a real browser in pytest) -----------------


class _FakePage:
    def __init__(self, rec: dict):
        self._rec = rec
        self.url = "about:blank"

    def goto(self, url, **kwargs):
        self._rec["navigated"].append((url, kwargs))
        # Simulate Playwright landing: same URL unless the test injects a
        # redirect target (review BLOCKER: post-goto re-check must see it).
        self.url = self._rec.get("redirect_to") or str(url)
        return None

    def click(self, selector, **kwargs):
        if self._rec.get("fail_on") == "click":
            raise RuntimeError("boom-click")
        self._rec["clicks"].append(selector)

    def fill(self, selector, text, **kwargs):
        self._rec["fills"].append((selector, text))

    def inner_text(self, selector, **kwargs):
        return "Visible secrets page body"

    def close(self):
        self._rec["closed"].append("page")


class _FakeContext:
    def __init__(self, rec: dict):
        self._rec = rec

    def new_page(self):
        return _FakePage(self._rec)

    def close(self):
        self._rec["closed"].append("context")


class _FakeBrowser:
    def __init__(self, rec: dict):
        self._rec = rec

    def new_context(self, **kwargs):
        self._rec["context_kwargs"] = kwargs
        return _FakeContext(self._rec)

    def close(self):
        self._rec["closed"].append("browser")


class _FakeChromium:
    def __init__(self, rec: dict):
        self._rec = rec

    def launch(self, **kwargs):
        self._rec["launch_kwargs"] = kwargs
        return _FakeBrowser(self._rec)


class _FakePlaywrightCM:
    def __init__(self, rec: dict):
        self.chromium = _FakeChromium(rec)
        self._rec = rec

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self._rec["closed"].append("playwright")
        return False


def _install_fake_playwright(monkeypatch, rec: dict) -> None:
    sub = types.ModuleType("playwright.sync_api")
    sub.sync_playwright = lambda: _FakePlaywrightCM(rec)
    pkg = types.ModuleType("playwright")
    pkg.__path__ = []  # mark as package
    pkg.sync_api = sub
    monkeypatch.setitem(sys.modules, "playwright", pkg)
    monkeypatch.setitem(sys.modules, "playwright.sync_api", sub)


def _rec() -> dict:
    return {"navigated": [], "clicks": [], "fills": [], "closed": [], "launch_kwargs": {}}


def _allow(record) -> bool:
    """Approval-channel stub for direct tool calls (self-guard needs one)."""
    return True


# --- 1. domain allowlist ------------------------------------------------------


def test_allowlist_matching_is_exact_or_subdomain() -> None:
    assert domain_allowed("example.com", ["example.com"]) is True
    assert domain_allowed("app.example.com", ["example.com"]) is True
    assert domain_allowed("EXAMPLE.com", ["example.com"]) is True  # case-insensitive
    assert domain_allowed("notexample.com", ["example.com"]) is False  # dot boundary
    assert domain_allowed("example.com.evil.com", ["example.com"]) is False
    assert domain_allowed("other.com", ["example.com"]) is False


def test_allowlist_empty_denies_everything() -> None:
    assert domain_allowed("example.com", []) is False
    assert domain_allowed("", ["example.com"]) is False


def test_empty_allowlist_denies_before_browser(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    with pytest.raises(BrowserDenied, match="allowed_domains"):
        browser_act("goto", "https://example.com/", DENY_ALL)


def test_listed_host_passes_gates_to_playwright_stage(monkeypatch) -> None:
    """Listed + public DNS reaches the lazy import (proves gates passed)."""
    _fake_dns(monkeypatch, public=True)
    try:
        import playwright  # noqa: F401
        pytest.skip("playwright installed — missing-backend path not exercisable")
    except ImportError:
        pass
    with pytest.raises(BrowserNotInstalled, match="pip install playwright"):
        browser_act("goto", "https://example.com/", ALLOW)


def test_private_ip_denies_even_if_listed(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=False)
    listed = ToolBrowserConfig(allowed_domains=["example.com"])
    with pytest.raises(BrowserDenied, match="[Bb]locked"):
        browser_act("goto", "https://example.com/", listed)


def test_non_http_scheme_denied() -> None:
    with pytest.raises(BrowserDenied, match="[Bb]locked"):
        check_url("file:///etc/passwd", ALLOW)


def test_check_url_returns_validated_host(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    assert check_url("https://app.example.com/page", ALLOW) == "app.example.com"


# --- 2. action subset + arg shapes (tool level) --------------------------------


def test_unknown_action_rejected(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)  # gates would pass — action check fires first
    with pytest.raises(BrowserDenied, match="[Uu]nknown browser action"):
        browser_act("eval_js", "https://example.com/", ALLOW)
    assert BROWSER_ACTIONS == {"goto", "click", "fill", "read_text"}


def test_click_requires_selector(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    with pytest.raises(BrowserDenied, match="selector"):
        browser_act("click", "https://example.com/", ALLOW)
    with pytest.raises(BrowserDenied, match="selector"):
        browser_act("click", "https://example.com/", ALLOW, selector="  ")


def test_fill_requires_selector_and_text(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    with pytest.raises(BrowserDenied, match="selector"):
        browser_act("fill", "https://example.com/", ALLOW, text="hi")
    with pytest.raises(BrowserDenied, match="'fill' requires"):
        browser_act("fill", "https://example.com/", ALLOW, selector="#q", text="")


def test_playwright_missing_error_is_actionable(monkeypatch) -> None:
    try:
        import playwright  # noqa: F401
        pytest.skip("playwright installed here — missing path not exercisable")
    except ImportError:
        pass
    _fake_dns(monkeypatch, public=True)
    with pytest.raises(BrowserNotInstalled, match="playwright install chromium"):
        browser_act("read_text", "https://example.com/", ALLOW)


# --- 3. fake-playwright execution ----------------------------------------------


def test_no_approval_channel_fails_closed_before_launch(monkeypatch) -> None:
    """Direct import with no checker never launches (review S1)."""
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    with pytest.raises(ConsentRequired):
        browser_act("goto", "https://example.com/", ALLOW)
    assert rec["navigated"] == []  # no browser touched


def test_fake_goto_navigates_and_reports(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    out = browser_act("goto", "https://example.com/", ALLOW, consent_checker=_allow)
    assert "https://example.com/" in out
    assert [u for u, _ in rec["navigated"]] == ["https://example.com/"]


def test_fake_click_fill_read_text(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    browser_act("click", "https://example.com/", ALLOW, selector="#btn", consent_checker=_allow)
    browser_act("fill", "https://example.com/", ALLOW, selector="#q", text="hello", consent_checker=_allow)
    out = browser_act("read_text", "https://example.com/", ALLOW, consent_checker=_allow)
    assert rec["clicks"] == ["#btn"]
    assert rec["fills"] == [("#q", "hello")]
    assert "Visible secrets" in out


def test_launch_is_headless_with_default_sandbox(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    browser_act("goto", "https://example.com/", ALLOW, consent_checker=_allow)
    assert rec["launch_kwargs"].get("headless") is True
    assert "--no-sandbox" not in json.dumps(rec["launch_kwargs"])


def test_context_disables_js_and_downloads(monkeypatch) -> None:
    """Renderer hardening (review S3): page JS off, downloads refused."""
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    browser_act("goto", "https://example.com/", ALLOW, consent_checker=_allow)
    assert rec["context_kwargs"].get("java_script_enabled") is False
    assert rec["context_kwargs"].get("accept_downloads") is False


def test_redirect_off_allowlist_aborts_before_action(monkeypatch) -> None:
    """Post-goto re-check (review BLOCKER): off-allowlist landing denied."""
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    rec["redirect_to"] = "https://evil.com/phish"
    _install_fake_playwright(monkeypatch, rec)
    with pytest.raises(BrowserDenied, match="allowed_domains"):
        browser_act("read_text", "https://example.com/", ALLOW, consent_checker=_allow)
    assert rec["clicks"] == []  # nothing acted on the landed page
    assert "page" in rec["closed"]  # handles still cleaned up


def test_redirect_to_private_host_aborts(monkeypatch) -> None:
    """Post-goto SSRF re-check: LAN landing denied even when listed."""
    import buddy_core.tools.web_search as ws

    def _split_dns(host, port):
        if host == "intranet.example.com":
            raise ValueError(
                "Blocked host 'intranet.example.com': resolves to non-public address 10.0.0.9"
            )
        return ["pinned"]

    monkeypatch.setattr(ws, "_resolve_public_addrs", _split_dns)
    rec = _rec()
    rec["redirect_to"] = "https://intranet.example.com/admin"  # listed subdomain, private IP
    _install_fake_playwright(monkeypatch, rec)
    with pytest.raises(BrowserDenied, match="[Bb]locked"):
        browser_act("goto", "https://example.com/", ALLOW, consent_checker=_allow)
    assert rec["clicks"] == []


def test_context_closed_on_success(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    browser_act("read_text", "https://example.com/", ALLOW, consent_checker=_allow)
    for handle in ("page", "context", "browser", "playwright"):
        assert handle in rec["closed"], rec["closed"]


def test_context_closed_on_mid_action_failure(monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    rec["fail_on"] = "click"
    _install_fake_playwright(monkeypatch, rec)
    with pytest.raises(RuntimeError, match="boom-click"):
        browser_act("click", "https://example.com/", ALLOW, selector="#btn", consent_checker=_allow)
    for handle in ("page", "context", "browser", "playwright"):
        assert handle in rec["closed"], rec["closed"]


# --- 4. executor consent hook (always pauses, even read_text) ------------------


def test_browser_always_pauses_without_approval(tmp_path, monkeypatch) -> None:
    """Every action — including read_text — pauses fail-closed."""
    _fake_dns(monkeypatch, public=True)
    _install_fake_playwright(monkeypatch, _rec())  # reach the pause, not the import error
    tools = _tools_cfg(tmp_path)
    tools.browser = BrowserConfig(allowed_domains=["example.com"])
    cases = [
        ("goto", {}),
        ("click", {"selector": "#b"}),
        ("fill", {"selector": "#q", "text": "hi"}),
        ("read_text", {}),
    ]
    for action, extra in cases:
        args = {"action": action, "url": "https://example.com/", **extra}
        result = execute_plan(Plan(steps=[ToolCall("browser_act", args)]), tools, "t-b5", _emit([]))
        assert not result.ok, action
        assert result.output.startswith(CONSENT_NEEDED_PREFIX), action
        assert result.steps_taken == 0, action


def test_browser_approve_executes_with_fake(tmp_path, monkeypatch) -> None:
    _fake_dns(monkeypatch, public=True)
    rec = _rec()
    _install_fake_playwright(monkeypatch, rec)
    tools = _tools_cfg(tmp_path)
    tools.browser = BrowserConfig(allowed_domains=["example.com"])
    plan = Plan(steps=[ToolCall("browser_act", {"action": "goto", "url": "https://example.com/"})])
    result = execute_plan(plan, tools, "t-b5-ok", _emit([]), consent_checker=lambda r: True)
    assert result.ok
    assert [u for u, _ in rec["navigated"]] == ["https://example.com/"]
    for handle in ("page", "context", "browser", "playwright"):
        assert handle in rec["closed"]


def test_browser_denied_by_allowlist_after_approval(tmp_path, monkeypatch) -> None:
    """Approval authorizes within policy — the allowlist stays absolute."""
    _fake_dns(monkeypatch, public=True)
    tools = _tools_cfg(tmp_path)  # repo default: deny-all
    tools.browser = BrowserConfig(allowed_domains=[])
    plan = Plan(steps=[ToolCall("browser_act", {"action": "goto", "url": "https://example.com/"})])
    result = execute_plan(plan, tools, "t-b5-deny", _emit([]), consent_checker=lambda r: True)
    assert not result.ok
    assert "allowed_domains" in result.output


def test_fill_text_redacted_in_tool_call_event(tmp_path, monkeypatch) -> None:
    """The pause is observable, but the typed secret never hits the event."""
    _fake_dns(monkeypatch, public=True)
    tools = _tools_cfg(tmp_path)
    tools.browser = BrowserConfig(allowed_domains=["example.com"])
    secret = "B5_FILL_SECRET_s3cr3t-p4ssw0rd"
    events: list = []
    plan = Plan(
        steps=[ToolCall("browser_act", {"action": "fill", "url": "https://example.com/", "selector": "#pw", "text": secret})]
    )
    result = execute_plan(plan, tools, "t-b5-redact", _emit(events))
    assert not result.ok  # paused — no checker
    assert events and events[0][0] == "tool_call"
    raw = json.dumps(events[0][1])
    assert secret not in raw
    assert events[0][1]["args"]["text"]["sha256"]


# --- 5. focus_check --------------------------------------------------------------


def test_focus_check_exact_foreground_match(monkeypatch) -> None:
    monkeypatch.setattr(auto_mod, "_foreground_window_title", lambda: "Untitled - Notepad")
    assert auto_mod.focus_check("Untitled - Notepad") is True
    assert auto_mod.focus_check("untitled - notepad") is True  # case-insensitive
    assert auto_mod.focus_check("  Untitled  -  Notepad  ") is True  # normalized
    assert auto_mod.focus_check("spotify") is False


def test_focus_check_rejects_spoofable_substrings(monkeypatch) -> None:
    """Substring matching is spoofable — exact match only (review S2)."""
    monkeypatch.setattr(auto_mod, "_foreground_window_title", lambda: "Bank - Evil")
    assert auto_mod.focus_check("Bank") is False
    assert auto_mod.focus_check("Bank - Evil") is True
    assert auto_mod.focus_check("FakeBank - Evil") is False


def test_focus_check_no_foreground_window_is_false(monkeypatch) -> None:
    monkeypatch.setattr(auto_mod, "_foreground_window_title", lambda: None)
    assert auto_mod.focus_check("notepad") is False


def test_focus_check_unsupported_platform(monkeypatch) -> None:
    monkeypatch.setattr(sys, "platform", "linux")
    with pytest.raises(RuntimeError, match="unsupported platform"):
        auto_mod.focus_check("notepad")


def test_focus_check_rejects_empty() -> None:
    with pytest.raises(ValueError, match="non-empty string"):
        auto_mod.focus_check("   ")


def test_focus_check_via_executor_needs_no_consent(tmp_path, monkeypatch) -> None:
    """Read-only poll executes directly (observes, never acts)."""
    monkeypatch.setattr(auto_mod, "_foreground_window_title", lambda: "Buddy - Chat")
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("focus_check", {"title_substring": "Buddy - Chat"})])
    result = execute_plan(plan, tools, "t-b5-focus", _emit([]))
    assert result.ok
    assert "found" in result.output


def test_focus_check_bad_shape_fails_closed(tmp_path) -> None:
    tools = _tools_cfg(tmp_path)
    plan = Plan(steps=[ToolCall("focus_check", {"title_substring": ""})])
    result = execute_plan(plan, tools, "t-b5-focus-bad", _emit([]))
    assert not result.ok
    assert "title_substring" in result.output


# --- 6. stubs pause-then-raise-honestly -------------------------------------------


def test_type_text_pauses_without_approval() -> None:
    with pytest.raises(ConsentRequired):
        auto_mod.type_text("hello")


def test_type_text_approve_then_raises_honestly() -> None:
    with pytest.raises(AutomationNotImplemented, match="later track"):
        auto_mod.type_text("hello", consent_checker=lambda rec: True)


def test_type_text_deny_stays_paused() -> None:
    with pytest.raises(ConsentRequired):
        auto_mod.type_text("hello", consent_checker=lambda rec: False)


def test_press_keys_pause_approve_deny() -> None:
    with pytest.raises(ConsentRequired):
        auto_mod.press_keys("Enter")
    with pytest.raises(AutomationNotImplemented, match="later track"):
        auto_mod.press_keys("ctrl+s", consent_checker=lambda rec: True)
    with pytest.raises(ConsentRequired):
        auto_mod.press_keys("ctrl+s", consent_checker=lambda rec: False)


def test_stubs_reject_empty_before_consent() -> None:
    seen: list = []
    with pytest.raises(ValueError):
        auto_mod.type_text("", consent_checker=lambda rec: seen.append(rec) or True)
    with pytest.raises(ValueError):
        auto_mod.press_keys("  ", consent_checker=lambda rec: seen.append(rec) or True)
    assert seen == []  # shape failure never reaches the consent queue


def test_stub_keystrokes_redacted_in_consent_record() -> None:
    """The consent identity must not carry raw keystroke text."""
    secret = "B5_STUB_SECRET_hunter2-keystrokes"
    seen: list = []
    with pytest.raises(ConsentRequired):
        auto_mod.type_text(secret, consent_checker=lambda rec: seen.append(rec) or False)
    assert seen
    assert secret not in json.dumps(seen[0])


def test_stubs_unreachable_via_executor(tmp_path) -> None:
    """type_text/press_keys are in NO scope — rejected before execution."""
    tools = _tools_cfg(tmp_path)
    for tool, args in (("type_text", {"text": "hi"}), ("press_keys", {"keys": "Enter"})):
        result = execute_plan(
            Plan(steps=[ToolCall(tool, args)]), tools, "t-b5-stub", _emit([]),
            consent_checker=lambda rec: True,
        )
        assert not result.ok
        assert "Unknown tool" in result.output  # validate_plan rejects, never executes


# --- 7. scope matrix ---------------------------------------------------------------


def test_b5_scope_matrix() -> None:
    assert scope_allows("researcher", "browser_act") is True
    assert scope_allows("executor", "focus_check") is True
    # Stubs live in NO scope — unreachable until the later track wires them.
    for tool in ("type_text", "press_keys", "delegate"):
        for category in ("coder", "executor", "researcher", "planner"):
            assert scope_allows(category, tool) is False, (category, tool)
    # Old boundaries hold: researcher never shells, executor never browses.
    assert scope_allows("researcher", "shell") is False
    assert scope_allows("executor", "browser_act") is False
    assert scope_allows("coder", "browser_act") is False
    assert scope_allows("no-such-agent", "browser_act") is False
    assert AGENT_TOOL_SCOPES["researcher"] >= {"web_search", "fetch_page", "browser_act"}
    assert AGENT_TOOL_SCOPES["executor"] >= {"shell", "focus_check"}
    assert EXECUTOR_TOOLS >= {"browser_act", "focus_check"}


# --- 8. validate_plan shapes ----------------------------------------------------------


def test_validate_browser_shapes() -> None:
    good = [
        {"action": "goto", "url": "https://example.com/"},
        {"action": "click", "url": "https://example.com/", "selector": "#b"},
        {"action": "fill", "url": "https://example.com/", "selector": "#q", "text": "hi"},
        {"action": "read_text", "url": "https://example.com/"},
    ]
    for args in good:
        validate_plan(Plan(steps=[ToolCall("browser_act", args)]), LIMITS)
    bad = [
        {"url": "https://example.com/"},  # missing action
        {"action": "eval_js", "url": "https://example.com/"},  # outside subset
        {"action": "goto"},  # missing url
        {"action": "goto", "url": "  "},  # empty url
        {"action": "click", "url": "https://example.com/"},  # missing selector
        {"action": "fill", "url": "https://example.com/", "selector": "#q"},  # missing text
        {"action": "fill", "url": "https://example.com/", "selector": "#q", "text": ""},
    ]
    for args in bad:
        with pytest.raises(PlanRejected):
            validate_plan(Plan(steps=[ToolCall("browser_act", args)]), LIMITS)


def test_validate_focus_check_shape() -> None:
    validate_plan(Plan(steps=[ToolCall("focus_check", {"title_substring": "notepad"})]), LIMITS)
    for args in ({}, {"title_substring": ""}, {"title_substring": "  "}, {"title_substring": 123}):
        with pytest.raises(PlanRejected):
            validate_plan(Plan(steps=[ToolCall("focus_check", args)]), LIMITS)


def test_validate_rejects_input_stubs_as_unknown() -> None:
    """Desktop input lands in a later track — plans naming it are rejected."""
    for tool, args in (("type_text", {"text": "hi"}), ("press_keys", {"keys": "Enter"})):
        with pytest.raises(PlanRejected, match="[Uu]nknown tool"):
            validate_plan(Plan(steps=[ToolCall(tool, args)]), LIMITS)


def test_known_tools_and_prompt_cover_b5() -> None:
    assert "browser_act" in KNOWN_TOOLS
    assert "focus_check" in KNOWN_TOOLS
    assert "type_text" not in KNOWN_TOOLS
    assert "press_keys" not in KNOWN_TOOLS
    from buddy_core.config import ToolsConfig

    prompt = _planner_system_prompt(ToolsConfig())
    assert "browser_act" in prompt
    assert "focus_check" in prompt


# --- 9. config --------------------------------------------------------------------------


def test_config_defaults_are_deny_all() -> None:
    from buddy_core.config import load_tools_config

    cfg = load_tools_config()  # repo config/tools.yaml now ships the block
    assert cfg.browser.allowed_domains == []
    assert not hasattr(cfg, "automation")  # dead key removed (review N4)


def test_config_parses_browser_block(tmp_path, monkeypatch) -> None:
    import buddy_core.config as cfg_mod

    import yaml

    doc = {
        "shell": {"allowlist": [], "denylist": []},
        "files": {"workspace_root": "~/buddy-workspace"},
        "web_search": {"backend": "duckduckgo", "searxng_url": ""},
        "agent_limits": {"max_plan_steps": 20, "max_recursion_depth": 2, "tool_timeout_seconds": 30},
        "memory": {"path": "logs/memory.jsonl", "cap": 500},
        "browser": {"allowed_domains": ["Example.com ", "app.example.org"]},
        "automation": {"enabled": True},  # stale key: ignored, never read
    }
    (tmp_path / "tools.yaml").write_text(yaml.safe_dump(doc), encoding="utf-8")
    monkeypatch.setattr(cfg_mod, "CONFIG_DIR", tmp_path)
    cfg = cfg_mod.load_tools_config()
    assert cfg.browser.allowed_domains == ["Example.com", "app.example.org"]
    assert not hasattr(cfg, "automation")


def test_config_garbage_fails_closed(tmp_path, monkeypatch) -> None:
    import buddy_core.config as cfg_mod

    import yaml

    doc = {"browser": {"allowed_domains": "not-a-list"}}
    (tmp_path / "tools.yaml").write_text(yaml.safe_dump(doc), encoding="utf-8")
    monkeypatch.setattr(cfg_mod, "CONFIG_DIR", tmp_path)
    cfg = cfg_mod.load_tools_config()
    assert cfg.browser.allowed_domains == []
