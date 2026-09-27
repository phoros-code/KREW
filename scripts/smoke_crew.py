"""Live smoke for the Track B2 CrewAI path (LAPTOP-ONLY).

Builds the REAL bounded crew (buddy_core/agents/crew.py) against the
local Ollama server and times one kickoff. NOT run by pytest
(testpaths=["tests"], and this file lives in scripts/ + has no test_
prefix) — run it by hand after flipping agents.framework to "crewai":

    .\\venv312\\Scripts\\python.exe scripts/smoke_crew.py [--topic "..."]

Exit 0 iff the crew returns non-empty, on-topic text; exit 1 on any
error, empty output, or unreachable Ollama. Prints latency + output so
the numbers can go straight into the ARCHITECTURE.md spike record.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from buddy_core.agents import crew as crew_module  # noqa: E402
from buddy_core.config import load_models_config  # noqa: E402
from buddy_core.orchestrator import OLLAMA_TIMEOUT_SECONDS  # noqa: E402


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Smoke-test the CrewAI research crew against local Ollama.")
    parser.add_argument("--topic", default="why the sky is blue", help="Topic for the bounded summary.")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    models = load_models_config()
    query = f"summarize: in at most 2 sentences, explain {args.topic}."
    context = (
        f"SOURCE: smoke — local\n"
        f"Sunlight scatters in the atmosphere; shorter (blue) wavelengths "
        f"scatter most, so the daytime sky looks blue.\n{query}"
    )
    # Same model the direct path would pick for a text request.
    model = models.target_model
    print(f"host={models.host} model={model} timeout={OLLAMA_TIMEOUT_SECONDS}s")
    t0 = time.perf_counter()
    try:
        text = crew_module.summarize_with_crew(query, context, models.host, model)
    except Exception as exc:  # noqa: BLE001 — smoke must report, not traceback
        print(f"SMOKE FAIL: {type(exc).__name__}: {exc}")
        return 1
    dt = time.perf_counter() - t0
    print(f"latency={dt:.1f}s len={len(text)}")
    print(f"output={text[:500]!r}")
    if not text.strip():
        print("SMOKE FAIL: empty crew output")
        return 1
    print("SMOKE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
