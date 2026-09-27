"""Speech-to-text via faster-whisper (Phase 1).

Tested with a fixture .wav under tests/fixtures/ — no live mic needed.
Requires ``pip install -e .[voice]``.
"""

from __future__ import annotations

import threading
import wave
from dataclasses import dataclass


@dataclass
class Transcription:
    text: str
    confidence: float  # mean log-prob mapped to 0..1; low => treat as unreliable


# Process-wide lazy model cache (Track B4): the Whisper weights load once
# per model name, guarded by a lock so concurrent first-utterances (the
# server runs transcribe in asyncio.to_thread — STT blocks, never block the
# event loop) can't double-load. Transcription itself is NOT serialized.
_MODEL_LOCK = threading.Lock()
_MODEL_CACHE: dict[str, object] = {}


def _load_model(model_name: str = "base"):
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise RuntimeError("faster-whisper not installed — run: pip install -e .[voice]") from exc
    return WhisperModel(model_name, device="cpu", compute_type="int8")


def _get_model(model_name: str = "base"):
    """Return the cached model, loading once per process on first use."""
    with _MODEL_LOCK:
        model = _MODEL_CACHE.get(model_name)
        if model is None:
            model = _load_model(model_name)
            _MODEL_CACHE[model_name] = model
        return model


def transcribe(wav_path: str, model_name: str = "base") -> Transcription:
    """Transcribe an audio file (wav/m4a/mp3/webm — faster-whisper decodes).

    Returns text + confidence (empty text on silence). Signature unchanged
    (path + model name) — the server passes its ephemeral upload path.
    """
    model = _get_model(model_name)
    segments, _info = model.transcribe(wav_path, beam_size=5)
    texts: list[str] = []
    probs: list[float] = []
    for seg in segments:
        texts.append(seg.text)
        # avg_logprob is negative; map to 0..1 (0 dB => 1.0, -1.0 => ~0.37).
        import math

        probs.append(math.exp(max(seg.avg_logprob, -5.0)))
    text = " ".join(texts).strip()
    confidence = sum(probs) / len(probs) if probs else 0.0
    return Transcription(text=text, confidence=confidence)


def audio_duration_seconds(path: str) -> float:
    """Best-effort clip duration for the /voice/transcribe envelope.

    WAV headers give it exactly; anything else returns 0.0. Never raises —
    duration is informational, transcription is the result.
    """
    try:
        with wave.open(str(path), "rb") as wav:
            rate = wav.getframerate() or 0
            if rate <= 0:
                return 0.0
            return wav.getnframes() / float(rate)
    except Exception:
        return 0.0
