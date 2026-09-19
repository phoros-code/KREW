"""CLI entrypoint: ``python -m buddy_core '<command>'``."""

from __future__ import annotations

import sys

from buddy_core.orchestrator import run


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if not args:
        print('Usage: python -m buddy_core "<command>"')
        return 2
    result = run(" ".join(args))
    print(result.output)
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
