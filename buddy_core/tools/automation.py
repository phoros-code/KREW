"""Desktop-automation SAFETY SCAFFOLD (Track B5) — no input injection yet.

Real keystroke injection without focus verification ships misfires: a
``type_text`` aimed at one window lands in whatever happens to be
focused. So this track lands the safe parts only:

- ``focus_check`` — read-only FOREGROUND-window title check (Windows-only,
  via ctypes Win32 ``GetForegroundWindow`` — no new dependencies).
  Returns True only on an EXACT (normalized, case-insensitive) title
  match: substring matching is spoofable (``"Bank"`` matches
  ``"Bank - Evil"``), so a future typing track must never gate on it.
  Everywhere else raises an "unsupported platform" error (fail closed).
- ``type_text`` / ``press_keys`` — CONSENT-GATED STUBS. They validate
  their shape, pause for laptop ops-consent like any destructive op, and
  then raise an honest ``AutomationNotImplemented`` ("desktop input lands
  in a later track") instead of injecting anything. No silent no-ops, no
  fake success.

SECURITY.md → Known limitations records the decision: blind automation
stays unimplemented on purpose until focus verification + consent +
per-op confirmation all hold together.
"""

from __future__ import annotations

import sys
from collections.abc import Callable


class AutomationNotImplemented(RuntimeError):
    """Honest stub error — desktop input lands in a later track."""


def _foreground_window_title() -> str | None:
    """Return the FOREGROUND window title (Windows only). Test seam.

    Split out so tests can monkeypatch the title without touching ctypes.
    None when there is no foreground window / empty title. Raises
    RuntimeError on non-Windows platforms (fail closed).
    """
    if sys.platform != "win32":
        raise RuntimeError(f"focus_check: unsupported platform {sys.platform!r} (Windows-only)")
    import ctypes

    try:
        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return None
        length = user32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return None
        buf = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buf, length + 1)
        return buf.value or None
    except Exception as exc:
        raise RuntimeError(f"focus_check cannot read the foreground window ({exc})") from None


def _normalize_title(title: str) -> str:
    """Collapse whitespace + lowercase for exact-match comparison."""
    return " ".join((title or "").split()).lower()


def focus_check(title: str) -> bool:
    """True on EXACT (normalized, case-insensitive) foreground-title match.

    Substring matching is deliberately NOT used: ``"Bank"`` must not match
    ``"Bank - Evil"`` (spoofable gate for a future typing track).
    Empty/non-string input raises ValueError; non-Windows raises
    RuntimeError (unsupported platform). Read-only — no consent needed
    (it observes, never acts).
    """
    if not isinstance(title, str) or not title.strip():
        raise ValueError("focus_check requires a non-empty string 'title'")
    actual = _foreground_window_title()
    if actual is None:
        return False
    return _normalize_title(actual) == _normalize_title(title)


def _pause_for_consent(tool: str, args: dict, reason: str, consent_checker: Callable | None) -> None:
    """Shared pause gate for the stubs (lazy import — no module cycle)."""
    from buddy_core.agents.executor import _require_op_consent

    _require_op_consent(tool, args, reason, consent_checker)


def type_text(text: str, consent_checker: Callable | None = None) -> str:
    """CONSENT-GATED STUB — validates, pauses for ops approval, then raises.

    Without laptop approval raises ConsentRequired (fail-closed pause,
    same as any destructive op). With approval raises
    AutomationNotImplemented — desktop input lands in a later track.
    """
    if not isinstance(text, str) or not text:
        raise ValueError("type_text requires non-empty string 'text'")
    _pause_for_consent(
        "type_text",
        {"text": text},
        "type_text would inject keystrokes into the focused window",
        consent_checker,
    )
    raise AutomationNotImplemented(
        "desktop input lands in a later track — type_text is a consent-gated stub"
    )


def press_keys(keys: str, consent_checker: Callable | None = None) -> str:
    """CONSENT-GATED STUB — validates, pauses for ops approval, then raises.

    ``keys`` is a non-empty string such as "Enter" or "ctrl+s". Same
    pause-then-raise-honestly contract as ``type_text``.
    """
    if not isinstance(keys, str) or not keys.strip():
        raise ValueError("press_keys requires a non-empty string 'keys'")
    _pause_for_consent(
        "press_keys",
        {"keys": keys},
        "press_keys would inject key presses into the focused window",
        consent_checker,
    )
    raise AutomationNotImplemented(
        "desktop input lands in a later track — press_keys is a consent-gated stub"
    )


__all__ = [
    "AutomationNotImplemented",
    "focus_check",
    "press_keys",
    "type_text",
]
