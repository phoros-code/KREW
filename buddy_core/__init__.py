"""Everyday Buddy core package (buddy-core).

Local-first, multi-agent AI assistant. All agent execution funnels through
``buddy_core.orchestrator.run`` — voice_loop.py and server/main.py are thin
front-ends over that single entrypoint (see ARCHITECTURE.md).
"""

from buddy_core.orchestrator import run

__all__ = ["run"]
