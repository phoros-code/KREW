"""Voice-loop tests — stt/tts/orchestrator stubbed, no mic or models needed."""

import wave
from pathlib import Path

import pytest

from voice import voice_loop
from voice.stt import Transcription


def _stub(monkeypatch, heard_text="what is the weather", confidence=0.9, orch_output="Sunny.", orch_ok=True):
    from buddy_core import orchestrator

    spoken: list[str] = []
    monkeypatch.setattr(
        "voice.stt.transcribe", lambda path, model_name="base": Transcription(heard_text, confidence)
    )
    monkeypatch.setattr(
        "voice.tts.speak", lambda text, out, model_path=None: spoken.append(text) or Path(out)
    )
    monkeypatch.setattr(
        "buddy_core.orchestrator.run",
        lambda cmd: orchestrator.TaskResult(ok=orch_ok, output=orch_output, task_id="t"),
    )
    return spoken


def test_happy_path_speaks_answer(monkeypatch, tmp_path) -> None:
    spoken = _stub(monkeypatch)
    reply = voice_loop.handle_utterance(tmp_path / "u.wav", voice_loop.LoopConfig(reply_wav=str(tmp_path / "r.wav")))
    assert reply == "Sunny."
    assert spoken == ["Sunny."]


def test_empty_transcription_fallback(monkeypatch, tmp_path) -> None:
    spoken = _stub(monkeypatch, heard_text="", confidence=0.0)
    reply = voice_loop.handle_utterance(tmp_path / "u.wav", voice_loop.LoopConfig(reply_wav=str(tmp_path / "r.wav")))
    assert reply == voice_loop.FALLBACK_EMPTY
    assert spoken == [voice_loop.FALLBACK_EMPTY]


def test_low_confidence_fallback(monkeypatch, tmp_path) -> None:
    spoken = _stub(monkeypatch, heard_text="mumble", confidence=0.1)
    reply = voice_loop.handle_utterance(tmp_path / "u.wav", voice_loop.LoopConfig(reply_wav=str(tmp_path / "r.wav")))
    assert reply == voice_loop.FALLBACK_EMPTY


def test_orchestrator_failure_fallback(monkeypatch, tmp_path) -> None:
    spoken = _stub(monkeypatch, orch_ok=False, orch_output="boom")
    reply = voice_loop.handle_utterance(tmp_path / "u.wav", voice_loop.LoopConfig(reply_wav=str(tmp_path / "r.wav")))
    assert reply == voice_loop.FALLBACK_FAILED
    assert spoken == [voice_loop.FALLBACK_FAILED]


def test_stt_crash_fallback(monkeypatch, tmp_path) -> None:
    import voice.stt

    spoken: list[str] = []
    monkeypatch.setattr("voice.stt.transcribe", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("mic dead")))
    monkeypatch.setattr("voice.tts.speak", lambda text, out, model_path=None: spoken.append(text) or Path(out))
    reply = voice_loop.handle_utterance(tmp_path / "u.wav", voice_loop.LoopConfig(reply_wav=str(tmp_path / "r.wav")))
    assert reply == voice_loop.FALLBACK_FAILED


def test_tts_duration_helper(tmp_path) -> None:
    from voice import tts

    p = tmp_path / "tone.wav"
    with wave.open(str(p), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 16000)  # 1.0s of silence
    assert tts.wav_duration_seconds(p) == pytest.approx(1.0, abs=0.01)


def test_speak_empty_rejected() -> None:
    from voice import tts

    with pytest.raises(ValueError):
        tts.speak("   ", "out.wav")
