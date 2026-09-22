"""Wake-word detection via openWakeWord (Phase 1).

Needs a live mic — verified by hand, not pytest (TESTING.md). Run:
    python -m voice.wake
and say the wake word; it prints WAKE DETECTED. Requires ``pip install -e .[voice]``.
"""

from __future__ import annotations

import collections

WAKE_WORD = "alexa"  # stand-in until custom "maxxy" model is trained
_THRESHOLD = 0.5
_HISTORY = 16


def _load_model(model_names: list[str] | None = None):
    try:
        from openwakeword.model import Model
    except ImportError as exc:
        raise RuntimeError("openWakeWord not installed — run: pip install -e .[voice]") from exc
    return Model(wakeword_models=model_names or [WAKE_WORD])


def listen_once(model_names: list[str] | None = None, timeout_seconds: float = 30.0) -> bool:
    """Block until the wake word is heard or the timeout expires. Needs a mic."""
    try:
        import pyaudio  # provided alongside openwakeword setups
    except ImportError as exc:
        raise RuntimeError("pyaudio not installed — run: pip install -e .[voice]") from exc

    import time

    import numpy as np

    model = _load_model(model_names)
    audio = pyaudio.PyAudio()
    stream = audio.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1280)
    scores: dict[str, collections.deque[float]] = collections.defaultdict(
        lambda: collections.deque(maxlen=_HISTORY)
    )
    deadline = time.time() + timeout_seconds
    try:
        while time.time() < deadline:
            pcm = np.frombuffer(stream.read(1280, exception_on_overflow=False), dtype=np.int16)
            for word, score in model.predict(pcm).items():
                scores[word].append(score)
                if len(scores[word]) == _HISTORY and max(scores[word]) >= _THRESHOLD:
                    return True
        return False
    finally:
        stream.stop_stream()
        stream.close()
        audio.terminate()


def main() -> int:
    print(f"Listening for {WAKE_WORD!r}… (Ctrl+C to stop)")
    if listen_once(timeout_seconds=120):
        print("WAKE DETECTED")
        return 0
    print("timed out, no wake word heard")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
