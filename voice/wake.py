"""Wake-word detection via openWakeWord (Phase 1).

Needs a live mic — verified by hand, not pytest (TESTING.md). Run:
    python -m voice.wake
and say the wake word; it prints WAKE DETECTED. Requires ``pip install -e .[voice]``.
"""

from __future__ import annotations

import collections
from pathlib import Path

# "alexa" is a documented STAND-IN — there is no community "maxy"
# openWakeWord model. It stays until a custom "maxy" model is trained
# (see voice/models/README.md). Do not treat alexa as the product name.
DEFAULT_WAKE_WORD = "alexa"
WAKE_WORD = DEFAULT_WAKE_WORD  # backwards-compat alias; prefer DEFAULT_WAKE_WORD

# Custom "maxy" model location. Training must produce BOTH files:
#   voice/models/maxy.onnx       (the model)
#   voice/models/maxy.onnx.json  (sidecar: "<model path>" + ".json")
CUSTOM_WAKE_MODEL = Path(__file__).parent / "models" / "maxy.onnx"
CUSTOM_WAKE_MODEL_JSON = Path(str(CUSTOM_WAKE_MODEL) + ".json")
_THRESHOLD = 0.5
_HISTORY = 16


def resolve_wake_models() -> list[str]:
    """Return the wake-word model list to load.

    If the trained custom model exists on disk, return [its path];
    otherwise fall back to the alexa stand-in name.
    """
    if CUSTOM_WAKE_MODEL.exists():
        print(f"wake: using custom maxy model ({CUSTOM_WAKE_MODEL})")
        return [str(CUSTOM_WAKE_MODEL)]
    print("wake: using alexa stand-in (train maxy per voice/models/README.md)")
    return [DEFAULT_WAKE_WORD]


def _load_model(model_names: list[str] | None = None):
    try:
        from openwakeword.model import Model
    except ImportError as exc:
        raise RuntimeError("openWakeWord not installed — run: pip install -e .[voice]") from exc
    # NOTE (verified vs installed openwakeword in venv312):
    #   Model.__init__(self, wakeword_models: List[str] = [], ...)
    # accepts EITHER pre-trained names ("alexa") OR local .onnx/.tflite
    # paths (os.path.exists branch → basename stem becomes the label).
    # All-.onnx input auto-switches inference_framework to "onnx", so a
    # custom path like voice/models/maxy.onnx needs no extra kwargs.
    return Model(wakeword_models=model_names or resolve_wake_models())


def listen_once(model_names: list[str] | None = None, timeout_seconds: float = 30.0) -> bool:
    """Block until the wake word is heard or the timeout expires. Needs a mic.

    model_names=None → auto-resolve via resolve_wake_models().
    """
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
    models = resolve_wake_models()
    print(f"Listening for {models}… (Ctrl+C to stop)")
    if listen_once(model_names=models, timeout_seconds=120):
        print("WAKE DETECTED")
        return 0
    print("timed out, no wake word heard")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
