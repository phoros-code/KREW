"""Wake-word detection via openWakeWord (Phase 1).

Needs a live mic — verified by hand, not pytest (TESTING.md). Run:
    python -m voice.wake
and say the wake word; it prints WAKE DETECTED. Requires ``pip install -e .[voice]``.

Single source of truth is the ``wake:`` section of ``config/models.yaml``
(stand-in word, custom model path, threshold), read via
``buddy_core.config.load_models_config``. The ``_FALLBACK_*`` values below
apply ONLY when the config file is missing — never as a parallel source.
"""

from __future__ import annotations

import collections
from pathlib import Path

# Fallback defaults for a missing config file only. "alexa" is a documented
# STAND-IN — there is no community "maxy" openWakeWord model. It stays until
# a custom "maxy" model is trained (see voice/models/README.md). Do not
# treat the stand-in as the product name.
_FALLBACK_STAND_IN = "alexa"
# Custom "maxy" model location. Training must produce BOTH files:
#   voice/models/maxy.onnx       (the model)
#   voice/models/maxy.onnx.json  (sidecar: "<model path>" + ".json")
_FALLBACK_CUSTOM_MODEL = Path(__file__).parent / "models" / "maxy.onnx"
_FALLBACK_THRESHOLD = 0.5
_HISTORY = 16


def get_wake_settings() -> tuple[str, Path, float]:
    """Return (stand_in, custom_model_path, threshold) from config/models.yaml.

    Falls back to the ``_FALLBACK_*`` defaults only when the config file is
    missing; a malformed config raises instead of silently defaulting.
    """
    from buddy_core.config import load_models_config

    try:
        cfg = load_models_config()
    except FileNotFoundError:
        return _FALLBACK_STAND_IN, _FALLBACK_CUSTOM_MODEL, _FALLBACK_THRESHOLD
    return cfg.wake_stand_in, Path(cfg.wake_custom_model), float(cfg.wake_threshold)


def resolve_wake_models() -> list[str]:
    """Return the wake-word model list to load.

    Stand-in word and custom path come from config/models.yaml: if the
    trained custom model exists on disk, return [its path]; otherwise fall
    back to the configured stand-in name.
    """
    stand_in, custom_model, _threshold = get_wake_settings()
    if custom_model.exists():
        print(f"wake: using custom maxy model ({custom_model})")
        return [str(custom_model)]
    print(f"wake: using {stand_in} stand-in (train maxy per voice/models/README.md)")
    return [stand_in]


def _detect(scores: dict[str, collections.deque[float]], threshold: float) -> bool:
    """Pure detection predicate: a full history window peaking >= threshold."""
    return any(len(hist) == _HISTORY and max(hist) >= threshold for hist in scores.values())


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

    model_names=None → auto-resolve via resolve_wake_models(). The detection
    threshold comes from config/models.yaml (see get_wake_settings).
    """
    try:
        import pyaudio  # provided alongside openwakeword setups
    except ImportError as exc:
        raise RuntimeError("pyaudio not installed — run: pip install -e .[voice]") from exc

    import time

    import numpy as np

    _, _, threshold = get_wake_settings()
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
                if _detect({word: scores[word]}, threshold):
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
