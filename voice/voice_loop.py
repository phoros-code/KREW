"""Voice loop — thin glue only, zero business logic (ARCHITECTURE.md).

wake → record N seconds → stt.transcribe → orchestrator.run() → tts.speak.
Any failure speaks a short fallback instead of crashing (PROMPTS.md Phase 1.5).
"""

from __future__ import annotations

import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

FALLBACK_EMPTY = "Sorry, I didn't catch that."
FALLBACK_FAILED = "Sorry, something went wrong handling that."
MIN_CONFIDENCE = 0.3
RECORD_SECONDS = 6


@dataclass
class LoopConfig:
    record_seconds: int = RECORD_SECONDS
    min_confidence: float = MIN_CONFIDENCE
    reply_wav: str = "reply.wav"


def record_wav(path: str | Path, seconds: int = RECORD_SECONDS, sample_rate: int = 16000) -> Path:
    """Record from the default mic. Needs a mic + pyaudio."""
    try:
        import pyaudio
    except ImportError as exc:
        raise RuntimeError("pyaudio not installed — run: pip install -e .[voice]") from exc
    out = Path(path)
    audio = pyaudio.PyAudio()
    stream = audio.open(format=pyaudio.paInt16, channels=1, rate=sample_rate, input=True, frames_per_buffer=1024)
    frames: list[bytes] = []
    try:
        for _ in range(int(sample_rate / 1024 * seconds)):
            frames.append(stream.read(1024, exception_on_overflow=False))
    finally:
        stream.stop_stream()
        stream.close()
        audio.terminate()
    with wave.open(str(out), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"".join(frames))
    return out


def handle_utterance(wav_path: str | Path, config: LoopConfig | None = None) -> str:
    """One loop iteration from a recorded file. Returns the reply text (also spoken).

    Pure glue over stt → orchestrator → tts so it is unit-testable with fakes.
    """
    from buddy_core import orchestrator
    from voice import stt, tts

    cfg = config or LoopConfig()
    try:
        heard = stt.transcribe(str(wav_path))
    except Exception:
        tts.speak(FALLBACK_FAILED, cfg.reply_wav)
        return FALLBACK_FAILED
    if not heard.text or heard.confidence < cfg.min_confidence:
        tts.speak(FALLBACK_EMPTY, cfg.reply_wav)
        return FALLBACK_EMPTY
    try:
        result = orchestrator.run(heard.text)
    except Exception:
        tts.speak(FALLBACK_FAILED, cfg.reply_wav)
        return FALLBACK_FAILED
    reply = result.output if result.ok else FALLBACK_FAILED
    tts.speak(reply, cfg.reply_wav)
    return reply


def main() -> int:
    """Run the always-on loop. Blocking — Ctrl+C to stop."""
    from voice import wake

    print("Buddy voice loop running. Say the wake word…")
    while True:
        if not wake.listen_once():
            continue
        with tempfile.TemporaryDirectory() as tmp:
            wav = record_wav(Path(tmp) / "utterance.wav")
            reply = handle_utterance(wav)
        print(f"buddy: {reply[:200]}")


if __name__ == "__main__":
    raise SystemExit(main())
