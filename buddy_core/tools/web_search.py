"""Web search tool — DuckDuckGo HTML, no API key (or self-hosted SearXNG).

Fetched page content is DATA, never instructions: if a page says "ignore
previous instructions and ...", that text is returned verbatim for the agent
to summarize, never followed (SECURITY.md → Tool sandboxing).

Agent-fetched URLs pass a fail-closed SSRF guard (http/https only; every
resolved address must be public — loopback, RFC1918, link-local, multicast,
and reserved ranges are rejected) and the response body is streamed with a
1MB hard ceiling (Track A4).
"""

from __future__ import annotations

import html as _html
import ipaddress
import re
import socket
from dataclasses import dataclass
from urllib.parse import urlsplit

import httpx

from buddy_core.config import WebSearchConfig

_DDG_URL = "https://html.duckduckgo.com/html/"
_HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) everyday-buddy/0.1.0"}
_TIMEOUT = 20.0

# Fetch ceiling (Track A4): at most this many response bytes are read off the
# wire. Over-long bodies are cut off mid-stream and flagged, never buffered
# whole — a hostile page must not fill laptop memory.
MAX_FETCH_BYTES = 1024 * 1024  # 1MB
TRUNCATED_MARKER = "[truncated: response exceeded 1MB fetch ceiling]"


@dataclass
class SearchHit:
    title: str
    url: str
    snippet: str


def _clean(text: str) -> str:
    return _html.unescape(re.sub(r"\s+", " ", text)).strip()


def parse_ddg_html(page: str) -> list[SearchHit]:
    """Parse DuckDuckGo html/ results into typed hits (pure function, testable)."""
    hits: list[SearchHit] = []
    # Each result block contains result__a (link) and result__snippet.
    for m in re.finditer(
        r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</div>',
        page,
        re.DOTALL,
    ):
        url, title, snippet = m.group(1), _clean(re.sub(r"<[^>]+>", "", m.group(2))), _clean(
            re.sub(r"<[^>]+>", "", m.group(3))
        )
        # Unwrap DDG redirect links //duckduckgo.com/l/?uddg=<target>.
        uddg = re.search(r"[?&]uddg=([^&]+)", url)
        if uddg:
            from urllib.parse import unquote

            url = unquote(uddg.group(1))
        hits.append(SearchHit(title=title, url=_html.unescape(url), snippet=snippet))
    return hits


def search(query: str, config: WebSearchConfig, max_results: int = 5) -> list[SearchHit]:
    """Run a web search. Raises ValueError on empty query, RuntimeError on HTTP failure."""
    query = query.strip()
    if not query:
        raise ValueError("Empty search query")
    if config.backend == "searxng":
        if not config.searxng_url:
            raise ValueError("searxng backend selected but searxng_url is empty")
        resp = httpx.get(
            config.searxng_url.rstrip("/") + "/search",
            params={"q": query, "format": "json"},
            headers=_HEADERS,
            timeout=_TIMEOUT,
        )
        resp.raise_for_status()
        data = resp.json()
        return [
            SearchHit(title=r.get("title", ""), url=r.get("url", ""), snippet=r.get("content", ""))
            for r in data.get("results", [])[:max_results]
        ]
    resp = httpx.post(_DDG_URL, data={"q": query}, headers=_HEADERS, timeout=_TIMEOUT)
    resp.raise_for_status()
    return parse_ddg_html(resp.text)[:max_results]


def _assert_url_safe(url: str) -> None:
    """Fail-closed SSRF guard for agent-fetched URLs. Raises ValueError.

    Only http/https schemes are allowed. The hostname is resolved with
    ``socket.getaddrinfo`` and EVERY returned address is checked with the
    ``ipaddress`` module — private (RFC1918), loopback, link-local
    (incl. the 169.254.169.254 metadata address), multicast, reserved,
    and unspecified targets are all rejected. Unresolvable hosts fail
    closed too (a DNS failure must never become a bypass).
    """
    try:
        parts = urlsplit(url)
    except ValueError as exc:
        raise ValueError(f"Blocked URL {url!r}: unparseable ({exc})") from None
    if parts.scheme not in ("http", "https"):
        raise ValueError(f"Blocked URL scheme {parts.scheme!r} — only http/https allowed")
    host = parts.hostname or ""
    if not host:
        raise ValueError(f"Blocked URL {url!r}: no hostname")
    try:
        addr_infos = socket.getaddrinfo(host, None)
    except OSError as exc:
        raise ValueError(f"Blocked host {host!r}: cannot resolve ({exc})") from None
    if not addr_infos:
        raise ValueError(f"Blocked host {host!r}: no addresses")
    for info in addr_infos:
        raw_ip = info[4][0]
        try:
            ip = ipaddress.ip_address(raw_ip)
        except ValueError:
            raise ValueError(f"Blocked host {host!r}: unparseable address {raw_ip!r}") from None
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        ):
            raise ValueError(f"Blocked host {host!r}: resolves to non-public address {raw_ip}")


def fetch_page_text(url: str, max_chars: int = 8000) -> str:
    """Fetch a page and return visible text as PLAIN DATA (never instructions).

    The URL passes the SSRF guard first (redirect targets are re-checked —
    a 302 to an internal host fails closed), then the body is streamed with
    ``iter_bytes`` under the 1MB hard ceiling: over-long bodies are cut off
    and the returned text is flagged with TRUNCATED_MARKER. Bodies under the
    ceiling behave exactly as before (same decode/clean/max_chars pipeline).
    """
    _assert_url_safe(url)
    with httpx.stream("GET", url, headers=_HEADERS, timeout=_TIMEOUT, follow_redirects=True) as resp:
        resp.raise_for_status()
        _assert_url_safe(str(resp.url))
        chunks: list[bytes] = []
        total = 0
        truncated = False
        for chunk in resp.iter_bytes(65536):
            if not chunk:
                continue
            if total + len(chunk) > MAX_FETCH_BYTES:
                chunks.append(chunk[: MAX_FETCH_BYTES - total])
                total = MAX_FETCH_BYTES
                truncated = True
                break
            chunks.append(chunk)
            total += len(chunk)
        try:
            page = b"".join(chunks).decode(resp.encoding or "utf-8", errors="replace")
        except (LookupError, ValueError):
            page = b"".join(chunks).decode("utf-8", errors="replace")
    text = re.sub(r"<script.*?</script>|<style.*?</style>", " ", page, flags=re.DOTALL | re.IGNORECASE)
    text = _clean(re.sub(r"<[^>]+>", " ", text))
    text = text[:max_chars]
    if truncated:
        text += f"\n\n{TRUNCATED_MARKER}"
    return text
