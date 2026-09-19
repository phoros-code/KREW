"""Speech-to-text via faster-whisper (Phase 1).

Tested with a fixture .wav under tests/fixtures/ — no live mic needed.
Requires ``pip install -e .[voice]``.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Transcription:
    text: str
    confidence: float  # mean log-prob mapped to 0..1; low => treat as unreliable


def _load_model(model_name: str = "base"):
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise RuntimeError("faster-whisper not installed — run: pip install -e .[voice]") from exc
    return WhisperModel(model_name, device="cpu", compute_type="int8")


def transcribe(wav_path: str, model_name: str = "base") -> Transcription:
    """Transcribe a .wav file. Returns text + confidence (empty text on silence)."""
    model = _load_model(model_name)
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
