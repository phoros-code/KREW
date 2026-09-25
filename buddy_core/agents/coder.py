"""CoderAgent — code generation scoped to the files tool (via the executor).

Contract (SECURITY.md rule 4): the file PATH never comes from the LLM.
``resolve_code_target`` extracts an explicit filename token from the user's
own command text (e.g. "write hello.py that prints hi" → "hello.py");
only the file CONTENT comes from the local model, and it is written
through the workspace jail (``tools/files.py``) by the executor's
validated ``write_file`` step. No filename in the command → no code
plan (falls through to research) — the agent never invents paths.
"""

from __future__ import annotations

import re

# Extensions the coder may create. No executables-as-source tricks: .exe/.bat/
# .cmd/.com/.msi/.ps1 are excluded — scripts stay readable source (.sh is
# allowed: POSIX half of CI runs them; .py/.js run under their interpreters).
CODE_EXTENSIONS = frozenset(
    {"py", "js", "ts", "sh", "md", "txt", "json", "yaml", "yml", "html", "css", "java", "c", "cs", "go", "rs"}
)

CODE_VERBS = ("write", "create", "save", "make", "generate")

# A filename token: word chars/dots/dashes/slashes, one of the allowed
# extensions. Traversal (".."), absolute, and drive paths are rejected
# after the match — belt and suspenders over the files-tool jail.
_FILENAME_RE = re.compile(
    r"(?:^|[\s\"'])([A-Za-z0-9_][\w\-./]*\.(" + "|".join(sorted(CODE_EXTENSIONS)) + r"))(?:[\s\"'.,!?;:]|$)",
    re.IGNORECASE,
)

# Hard cap on generated content — a runaway model must not fill the disk.
MAX_CODE_CHARS = 20000


def resolve_code_target(command: str) -> str | None:
    """Return the explicit filename in a code-like command, else None.

    Requires a code verb AND a filename token with an allowed extension.
    Returns None for bare-verb commands ("write a poem") so they fall
    through to research instead of guessing a path.
    """
    words = command.strip().lower().split()
    if not words or words[0] not in CODE_VERBS:
        return None
    match = _FILENAME_RE.search(command)
    if not match:
        return None
    target = match.group(1)
    if ".." in target or target.startswith(("/", "\\")) or ":" in target:
        return None
    return target


def draft_content(client: object, model: str, command: str, rel_path: str) -> str:
    """Ask the local model for raw file content. Raises on failure/overrun."""
    resp = client.chat(
        model=model,
        messages=[
            {
                "role": "system",
                "content": (
                    f"You are Everyday Buddy's code writer. Output ONLY the raw "
                    f"file content for '{rel_path}' — no markdown fences, no "
                    f"explanations, no trailing commentary. Keep it short and correct."
                ),
            },
            {"role": "user", "content": command},
        ],
        options={"temperature": 0.2},
    )
    content = resp["message"]["content"].strip()
    if len(content) > MAX_CODE_CHARS:
        raise ValueError(f"Generated content too large ({len(content)} chars, max {MAX_CODE_CHARS})")
    if not content:
        raise ValueError("Model returned empty content")
    return content
