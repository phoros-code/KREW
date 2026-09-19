"""Text-to-speech via Piper (Phase 1).

Writes a .wav for the input text. Tested by asserting the output is non-empty
with a plausible duration — no speakers needed. Requires ``pip install -e .[voice]``
plus a downloaded Piper voice model (see VOICE_MODEL_URL below).
"""

from __future__ import annotations

import wave
from pathlib import Path

# Default voice: en_US-lessac-medium. Download once into voice/models/:
#   https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
#   (+ the matching .onnx.json config beside it)
DEFAULT_VOICE_MODEL = Path(__file__).resolve().parent / "models" / "en_US-lessac-medium.onnx"


def _load_voice(model_path: str | Path):
    try:
        from piper import PiperVoice
    except ImportError as exc:
        raise RuntimeError("piper-tts not installed — run: pip install -e .[voice]") from exc
    path = Path(model_path)
    if not path.exists():
        raise FileNotFoundError(
            f"Piper voice model not found: {path}. Download it per the notes in voice/tts.py."
        )
    return PiperVoice.load(str(path))


def speak(text: str, out_wav: str, model_path: str | Path = DEFAULT_VOICE_MODEL) -> Path:
    """Synthesize text to a .wav file. Returns the output path."""
    text = text.strip()
    if not text:
        raise ValueError("Nothing to speak — empty text")
    voice = _load_voice(model_path)
    out = Path(out_wav)
    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(voice.config.sample_rate)
        for chunk in voice.synthesize(text):
            wav.writeframes(chunk.audio_int16_bytes)
    return out


def wav_duration_seconds(path: str | Path) -> float:
    """Plausible-duration check helper used by tests."""
    with wave.open(str(path), "rb") as wav:
        return wav.getnframes() / float(wav.getframerate() or 1)
