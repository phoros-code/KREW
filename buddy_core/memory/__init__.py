"""Local conversation memory — bounded JSONL store, laptop-only (Track B3)."""

from buddy_core.memory.memory import (
    MEMORY_CAP_DEFAULT,
    MEMORY_CONTEXT_CHARS,
    MEMORY_KIND_CHARS,
    MEMORY_RECALL_DEFAULT,
    MEMORY_TEXT_CHARS,
    MemoryStore,
    format_memories_for_prompt,
    resolve_store_path,
)

__all__ = [
    "MemoryStore",
    "format_memories_for_prompt",
    "resolve_store_path",
    "MEMORY_CAP_DEFAULT",
    "MEMORY_CONTEXT_CHARS",
    "MEMORY_KIND_CHARS",
    "MEMORY_RECALL_DEFAULT",
    "MEMORY_TEXT_CHARS",
]
