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

import contextlib
import html as _html
import ipaddress
import re
import socket
import threading
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

# Manual redirect bound (Track E1 SHOULD-04/05): at most this many HTTP
# hops (initial + redirects) are followed. Every hop is re-resolved,
# re-validated, and DNS-pinned; exceeding the bound fails closed.
MAX_REDIRECT_HOPS = 5
_REDIRECT_STATUSES = (301, 302, 303, 307, 308)


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
    """Run a web search. Raises ValueError on empty query, RuntimeError on HTTP failure.

    Both backends go through the same DNS-pinned, manually-redirected
    transport as page fetches (review follow-up: the SearXNG/DDG calls were
    unpinned). The fixed DDG host and the operator-configured SearXNG URL
    are validated on every call.
    """
    import json as _json

    query = query.strip()
    if not query:
        raise ValueError("Empty search query")
    if config.backend == "searxng":
        if not config.searxng_url:
            raise ValueError("searxng backend selected but searxng_url is empty")
        body, _, _, _ = _request_with_redirects(
            "GET",
            config.searxng_url.rstrip("/") + "/search",
            params={"q": query, "format": "json"},
        )
        try:
            data = _json.loads(body.decode("utf-8", errors="replace"))
        except ValueError as exc:
            raise RuntimeError(f"SearXNG returned non-JSON payload ({exc})") from None
        return [
            SearchHit(title=r.get("title", ""), url=r.get("url", ""), snippet=r.get("content", ""))
            for r in data.get("results", [])[:max_results]
        ]
    body, _, _, _ = _request_with_redirects("POST", _DDG_URL, data={"q": query})
    return parse_ddg_html(body.decode("utf-8", errors="replace"))[:max_results]


def _default_port(scheme: str) -> int:
    return 443 if scheme == "https" else 80


def _resolve_public_addrs(host: str, port: int | str | None) -> list:
    """Resolve + validate once. Returns the pinned getaddrinfo list.

    EVERY returned address must be public (same checks as the SSRF guard) —
    otherwise ValueError (fail closed). Callers pin the returned list for
    the subsequent connect so a rebinding DNS answer cannot swap in a
    private address between check and use.
    """
    try:
        addr_infos = socket.getaddrinfo(host, port)
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
    return list(addr_infos)


@contextlib.contextmanager
def _pinned_getaddrinfo(host: str, pinned: list):
    """Pin one hostname to its validated address list for the enclosed hop.

    Thread-local: only the entering thread sees the pin (checked via
    threading.get_ident()); every other thread passes through to the real
    function. Exact-host match (``h == host``) returns the pinned sockaddr
    list; everything else passes through to the real getaddrinfo captured
    at entry (which honours test monkeypatches).
    """
    real = socket.getaddrinfo
    tid = threading.get_ident()

    def _shim(h, p, *args, **kwargs):
        if threading.get_ident() == tid and h == host:
            return pinned
        return real(h, p, *args, **kwargs)

    socket.getaddrinfo = _shim  # type: ignore[assignment]
    try:
        yield pinned
    finally:
        try:
            socket.getaddrinfo = real  # type: ignore[assignment]
        except Exception:
            pass


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
    port = parts.port or _default_port(parts.scheme)
    _resolve_public_addrs(host, port)


def _redirect_location(resp) -> str | None:
    try:
        headers = getattr(resp, "headers", None) or {}
        get = getattr(headers, "get", None)
        if callable(get):
            for key in ("location", "Location", "LOCATION"):
                try:
                    val = get(key)
                except Exception:
                    val = None
                if val:
                    return str(val)
        return None
    except Exception:
        return None


@contextlib.contextmanager
def _pinned_hop(method: str, url: str, **kwargs):
    """Open one pinned, non-redirected streaming request; yield the response.

    Validates + resolves the hop's host, pins it for the enclosed request,
    and forces ``follow_redirects=False`` (passed explicitly so tests can
    pin the contract) — callers follow hops manually so every hop is
    re-validated (SHOULD-05). Transport is ``httpx.stream`` (module
    attribute, mockable). Raises ValueError on unsafe targets.
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
    port = parts.port or _default_port(parts.scheme)
    pinned = _resolve_public_addrs(host, port)
    kwargs["follow_redirects"] = False
    with _pinned_getaddrinfo(host, pinned):
        with httpx.stream(method, url, headers=_HEADERS, timeout=_TIMEOUT, **kwargs) as resp:
            yield resp


def _read_body_capped(resp) -> tuple[bytes, bool]:
    """Read a streaming body under the 1MB ceiling. Returns (body, truncated)."""
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
    return b"".join(chunks), truncated


def _request_with_redirects(
    method: str, url: str, **kwargs
) -> tuple[bytes, str, str | None, bool]:
    """Pinned request with manual redirect following. Returns (body, final_url, encoding, truncated).

    Every hop is validated + resolved + pinned; redirects convert to plain
    GET without a body (303 semantics for all 301/302/303/307/308 — a
    redirected POST body is never forwarded to a new host). Exceeding
    MAX_REDIRECT_HOPS or any unsafe hop fails closed with ValueError.
    """
    from urllib.parse import urljoin

    current_url = url
    current_method = method
    current_kwargs = dict(kwargs)
    for hop in range(MAX_REDIRECT_HOPS):
        with _pinned_hop(current_method, current_url, **current_kwargs) as resp:
            # Final-URL check (covers transports that report a different
            # URL than requested). Inside the pin so the check itself
            # cannot be rebound.
            _assert_url_safe(str(getattr(resp, "url", current_url)))
            status = getattr(resp, "status_code", 200)
            location = _redirect_location(resp)
            if status in _REDIRECT_STATUSES and location:
                if hop >= MAX_REDIRECT_HOPS - 1:
                    raise ValueError(
                        f"Blocked: too many redirects (exceeded {MAX_REDIRECT_HOPS} hops)"
                    )
                current_url = urljoin(current_url, location)
                # Never forward a request body to a new host: redirects
                # continue as plain GET (request-target stays in the URL).
                current_method = "GET"
                current_kwargs = {
                    k: v for k, v in current_kwargs.items() if k not in ("data", "content", "files")
                }
                continue
            resp.raise_for_status()
            _assert_url_safe(str(getattr(resp, "url", current_url)))
            body, truncated = _read_body_capped(resp)
            return (
                body,
                str(getattr(resp, "url", current_url)),
                getattr(resp, "encoding", None),
                truncated,
            )
    raise ValueError(f"Blocked: too many redirects (exceeded {MAX_REDIRECT_HOPS} hops)")


def fetch_page_text(url: str, max_chars: int = 8000) -> str:
    """Fetch a page and return visible text as PLAIN DATA (never instructions).

    Track E1 SHOULD-04/05 DNS-pinned fetch via _request_with_redirects:
    resolve+validate once per hop, pin that hop's addresses via a
    thread-local getaddrinfo shim, and follow redirects manually
    (follow_redirects=False, max 5 hops — every hop re-resolved +
    validated + pinned, fail closed on violation or hop-limit).
    The body is streamed with ``iter_bytes`` under the 1MB hard ceiling:
    over-long bodies are cut off and flagged with TRUNCATED_MARKER. Bodies
    under the ceiling behave exactly as before (same decode/clean/max_chars
    pipeline). The final URL is re-checked after the transfer.
    """
    body, _, encoding, truncated = _request_with_redirects("GET", url)
    try:
        page = body.decode(encoding or "utf-8", errors="replace")
    except (LookupError, ValueError):
        page = body.decode("utf-8", errors="replace")
    text = re.sub(r"<script.*?</script>|<style.*?</style>", " ", page, flags=re.DOTALL | re.IGNORECASE)
    text = _clean(re.sub(r"<[^>]+>", " ", text))
    text = text[:max_chars]
    if truncated:
        text += f"\n\n{TRUNCATED_MARKER}"
    return text
