"""Browser automation tool — Playwright-backed, allowlisted, consent-gated.

Track B5. ``browser_act`` is the ONLY browser entrypoint, with a fixed
action subset — ``{goto, click, fill, read_text}``. There is deliberately
no file-download action, no JS-eval action, and no navigation outside an
explicit ``goto`` (every action navigates to its ``url`` first, then acts).

Safety layers (defense in depth, see SECURITY.md):

1. SSRF guard — every ``url`` passes
   ``web_search._assert_url_safe`` (http/https only; the host must resolve
   to public addresses — loopback/RFC1918/link-local/multicast/reserved
   rejected, unresolvable fails closed). Reused, not reimplemented.
2. Domain allowlist — ``config/tools.yaml`` → ``browser.allowed_domains``
   (default empty = deny-all). Exact or subdomain-suffix match,
   case-insensitive. A listed-but-private target is still denied by (1).
3. Consent — every ``browser_act`` call is DESTRUCTIVE-CLASS and enforces
   the laptop ops-consent pause ITSELF (``consent_checker`` param, same
   gate the executor uses) — even for ``read_text`` (page content can
   contain secrets; consistent pausing is simpler to reason about than
   read/write split rules). A call with no approval channel fails closed
   and never launches a browser, so no future direct import can bypass
   the executor's pause.
4. Sandbox — Playwright launches Chromium headless with the DEFAULT
   sandbox (``--no-sandbox`` is never passed), page JavaScript disabled
   and downloads refused at the context level. The browser, context, and
   page are all closed in ``finally`` blocks (no zombie browsers).
5. Post-navigation re-check — Playwright follows redirects internally,
   so after ``page.goto`` the LANDED url is re-run through ``check_url``
   (SSRF re-resolve + allowlist) before any click/fill/read. A redirect
   off-allowlist or onto a private host aborts with the page closed.

Playwright is imported lazily so the core still runs without it; callers
get a clear install error instead of an ImportError traceback.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from urllib.parse import urlsplit

from buddy_core.tools.web_search import _assert_url_safe

# Fixed action subset — anything else is rejected (fail closed).
BROWSER_ACTIONS = frozenset({"goto", "click", "fill", "read_text"})

# Per-step browser timeout (ms) — no unbounded page load/click/fill.
PLAYWRIGHT_TIMEOUT_MS = 15_000

# read_text ceiling — a hostile page must not fill memory or the event log.
MAX_READ_CHARS = 8000


class BrowserDenied(ValueError):
    """Raised when a browser op fails a safety gate (fail closed)."""


class BrowserNotInstalled(RuntimeError):
    """Raised when Playwright is not installed (lazy-import error)."""


@dataclass
class BrowserConfig:
    """Operator browser scope. Empty allowlist = deny-all (fail closed)."""

    allowed_domains: list[str] = field(default_factory=list)


def _normalize_entries(entries: list[str]) -> list[str]:
    """Lowercase, strip, drop empties and leading dots from allowlist entries."""
    cleaned: list[str] = []
    for entry in entries:
        if not isinstance(entry, str):
            continue
        norm = entry.strip().lower().lstrip(".")
        if norm:
            cleaned.append(norm)
    return cleaned


def domain_allowed(host: str, allowed_domains: list[str]) -> bool:
    """True when ``host`` matches the allowlist (exact or subdomain suffix).

    Empty allowlist denies everything. Matching is case-insensitive:
    ``example.com`` allows ``example.com`` and ``app.example.com`` but
    not ``notexample.com`` (suffix match requires the dot boundary).
    Pure function — unit-testable without DNS or a browser.
    """
    host = (host or "").strip().lower()
    if not host:
        return False
    entries = _normalize_entries(allowed_domains)
    if not entries:
        return False
    for entry in entries:
        if host == entry or host.endswith("." + entry):
            return True
    return False


def _host_of(url: str) -> str:
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def check_url(url: str, config: BrowserConfig) -> str:
    """Run both URL gates; return the validated hostname. Raises BrowserDenied.

    Order: SSRF guard first (a target must be public no matter who
    listed it — a listed name rebound to LAN stays denied), then the
    operator domain allowlist (default deny-all).
    """
    if not isinstance(url, str) or not url.strip():
        raise BrowserDenied("browser_act requires a non-empty string 'url'")
    try:
        _assert_url_safe(url)
    except ValueError as exc:
        raise BrowserDenied(f"Blocked browser URL: {exc}") from None
    host = _host_of(url)
    if not domain_allowed(host, config.allowed_domains):
        raise BrowserDenied(
            f"Blocked browser URL: host {host!r} is not in browser.allowed_domains"
        )
    return host


def browser_act(
    action: str,
    url: str,
    config: BrowserConfig,
    selector: str | None = None,
    text: str | None = None,
    consent_checker=None,
) -> str:
    """Perform one allowlisted browser action. Raises on any failure.

    ``action`` is one of ``BROWSER_ACTIONS``; ``url`` passes both gates
    in ``check_url``; ``click``/``fill`` require a non-empty ``selector``;
    ``fill`` additionally requires ``text`` (non-empty — fail closed).
    ``read_text`` returns visible body text truncated to MAX_READ_CHARS.
    Page content is DATA, never instructions (SECURITY.md).

    ``consent_checker`` is the laptop-approval callback (same gate the
    executor uses). None fails closed with ConsentRequired BEFORE any
    browser launches — direct imports cannot bypass the pause.
    """
    if action not in BROWSER_ACTIONS:
        raise BrowserDenied(
            f"Unknown browser action {action!r} — allowed: {sorted(BROWSER_ACTIONS)}"
        )
    check_url(url, config)
    if action in ("click", "fill"):
        if not isinstance(selector, str) or not selector.strip():
            raise BrowserDenied(f"browser_act {action!r} requires a non-empty 'selector'")
    if action == "fill":
        if not isinstance(text, str) or not text:
            raise BrowserDenied("browser_act 'fill' requires non-empty 'text'")

    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise BrowserNotInstalled(
            "playwright not installed — run: pip install playwright && playwright install chromium"
        ) from exc
    # Pause AFTER the backend check: a missing Playwright fails fast
    # without bothering the laptop approver for an op that cannot run.
    _pause_for_consent(action, url, selector, text, consent_checker)

    # Default sandbox ON (never --no-sandbox), headless only, page JS off,
    # downloads refused. Every handle closes in finally — a failure
    # mid-action must not leave a zombie browser behind.
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            context = browser.new_context(java_script_enabled=False, accept_downloads=False)
            try:
                page = context.new_page()
                try:
                    page.goto(url, timeout=PLAYWRIGHT_TIMEOUT_MS)
                    # Post-navigation re-check (review BLOCKER): Playwright
                    # follows redirects internally, so the LANDED url must
                    # pass both gates before anything acts on the page.
                    landed = str(getattr(page, "url", url) or url)
                    check_url(landed, config)
                    if action == "goto":
                        return f"Opened {landed}"
                    if action == "click":
                        page.click(selector, timeout=PLAYWRIGHT_TIMEOUT_MS)  # type: ignore[arg-type]
                        return f"Clicked {selector} on {landed}"
                    if action == "fill":
                        page.fill(selector, text, timeout=PLAYWRIGHT_TIMEOUT_MS)  # type: ignore[arg-type]
                        return f"Filled {selector} on {landed}"
                    # read_text
                    body = page.inner_text("body", timeout=PLAYWRIGHT_TIMEOUT_MS)
                    if not isinstance(body, str):
                        body = str(body)
                    return body[:MAX_READ_CHARS]
                finally:
                    try:
                        page.close()
                    except Exception:
                        pass
            finally:
                try:
                    context.close()
                except Exception:
                    pass
        finally:
            try:
                browser.close()
            except Exception:
                pass


def _pause_for_consent(action: str, url: str, selector, text, consent_checker) -> None:
    """Self-guard: no approval channel fails closed before launch (S1).

    This is the ONLY pause for browser_act (the executor does not
    pre-pause), so the op identity is single and canonical. ``text`` is
    included — ``op_record_for_step`` redacts it to length+sha, so fill
    secrets never enter the consent queue while the sha stays stable.
    Explicit nulls are dropped (plans carrying ``"selector": null`` for a
    goto pause under the same identity as the canonical shape).
    """
    from buddy_core.agents.executor import _require_op_consent

    args: dict = {"action": action, "url": url}
    if selector is not None:
        args["selector"] = selector
    if text is not None:
        args["text"] = text
    _require_op_consent(
        "browser_act",
        args,
        "browser_act always requires laptop consent. Approving lets the "
        "agent fetch this page, and the fetched text is kept in the "
        "event log (visible on the phone) — approve only pages whose "
        "content you are fine with persisting",
        consent_checker,
    )


__all__ = [
    "BROWSER_ACTIONS",
    "MAX_READ_CHARS",
    "PLAYWRIGHT_TIMEOUT_MS",
    "BrowserConfig",
    "BrowserDenied",
    "BrowserNotInstalled",
    "browser_act",
    "check_url",
    "domain_allowed",
]
