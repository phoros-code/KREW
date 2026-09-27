"""ResearchAgent — web research scoped to search + fetch + summarize.

Track B1: real agent behind ``run_research``. Fetched page content is
DATA, never instructions (SECURITY.md): pages are concatenated into the
summarization context verbatim and never interpreted as tool calls.

Pure-function seams: ``search_fn`` / ``fetch_fn`` / ``llm_summarize`` are
injected so tests use fakes (no Ollama needed). The orchestrator passes
wrappers that emit the same redacted ``tool_call`` events as the old
inlined flow.
"""

from __future__ import annotations

from typing import Any, Callable


def _limit_value(limits: Any, name: str, default: int) -> int:
    """Read an int limit from a dict or an attribute object (with default)."""
    try:
        if limits is None:
            return default
        if isinstance(limits, dict):
            value = limits.get(name, default)
        else:
            value = getattr(limits, name, default)
        if value is None:
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def _hit_field(hit: Any, name: str) -> str:
    if isinstance(hit, dict):
        value = hit.get(name, "")
    else:
        value = getattr(hit, name, "")
    return value if isinstance(value, str) else str(value or "")


def run_research(
    query: str,
    limits: Any,
    search_fn: Callable[..., Any],
    fetch_fn: Callable[..., str],
    llm_summarize: Callable[..., str],
) -> str:
    """Search, fetch top pages as inert data, summarize via LLM.

    - ``limits`` carries ``max_results`` / ``max_pages`` / ``max_chars``
      (dict or attribute object; defaults 5/2/8000 matching
      ``planner.build_research_plan``).
    - ``search_fn(query, max_results)`` returns hits with
      title/url/snippet (SearchHit objects or dicts).
    - ``fetch_fn(url, max_chars)`` returns page text as DATA.
    - ``llm_summarize(query, context)`` (or ``llm_summarize(context)``)
      returns the final summary string.

    Returns "No search results found." when the search yields nothing
    (summarizer is not called). Fetch failures become
    "(fetch failed: ...)" context lines — never raised.
    """
    max_results = _limit_value(limits, "max_results", 5)
    max_pages = _limit_value(limits, "max_pages", 2)
    max_chars = _limit_value(limits, "max_chars", 8000)

    hits = search_fn(query, max_results)
    if not hits:
        return "No search results found."

    context_parts: list[str] = []
    for hit in list(hits)[:max(0, max_pages)]:
        url = _hit_field(hit, "url")
        title = _hit_field(hit, "title")
        snippet = _hit_field(hit, "snippet")
        try:
            body = fetch_fn(url, max_chars)
        except Exception as exc:  # noqa: BLE001 — fail-closed per-page
            body = f"(fetch failed: {exc})"
        if body is None:
            body = ""
        context_parts.append(f"SOURCE: {title} — {url}\n{snippet}\n{body}")

    context = "\n\n---\n\n".join(context_parts)
    try:
        return llm_summarize(query, context)
    except TypeError:
        # Accept single-arg fakes: llm_summarize(context).
        return llm_summarize(context)
