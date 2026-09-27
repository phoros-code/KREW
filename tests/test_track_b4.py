"""Track B4 server half (POST /voice/transcribe) tests.

Covers: auth/proximity matrix (401/403), missing audio field (400),
disallowed content-type (400), oversize (413 body_too_large), happy path
with STT mocked (tiny wav bytes), silence shape (200, never 4xx), the 501
path when faster-whisper is missing (real here + monkeypatched), no temp
leftovers after each request, and event redaction (the endpoint emits no
events — a marker transcript must not appear raw in events.jsonl).
"""

from __future__ import annotations

import io
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path

import pytest
import yaml
from fastapi.testclient import TestClient

from voice.stt import Transcription

TOKEN = "test-token-b4"
APPROVAL_SECRET = "b4" * 32  # 64-hex deterministic
MARKER = "B4_MARKER_SECRET_9c2e7a1f4d8b"


def _security(path: Path, mode: str = "lan_only") -> None:
    doc: dict = {
        "auth": {
            "token": TOKEN,
            "consent_approval_secret": APPROVAL_SECRET,
            "max_failed_attempts": 5,
            "lockout_minutes": 15,
            "idle_timeout_minutes": 60,
            "token_absolute_max_age_days": 30,
            "issued_at": datetime.now(timezone.utc).isoformat(),
        },
        "proximity": {"mode": mode, "rssi_near_threshold": -60, "fail_mode": "far"},
    }
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


@pytest.fixture()
def app_near(tmp_path):
    from server.main import create_app

    sec = tmp_path / "security.yaml"
    _security(sec, "lan_only")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


@pytest.fixture()
def app_far(tmp_path):
    from server.main import create_app

    sec = tmp_path / "security.yaml"
    _security(sec, "lan_plus_bluetooth")
    return create_app(security_path=sec, event_log=tmp_path / "events.jsonl")


def _auth(extra: dict | None = None) -> dict:
    headers = {"Authorization": f"Bearer {TOKEN}"}
    if extra:
        headers.update(extra)
    return headers


def _tiny_wav(seconds: float = 0.1, sample_rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * int(sample_rate * seconds))
    return buf.getvalue()


def _wav_file(data: bytes, name: str = "clip.wav") -> dict:
    return {"audio": (name, data, "audio/wav")}


def _stt_leftovers() -> list[Path]:
    return [p for p in Path(tempfile.gettempdir()).iterdir() if p.name.startswith("buddy-stt-")]


# --- auth/proximity matrix --------------------------------------------------


def test_transcribe_needs_auth(app_near) -> None:
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()))
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


def test_transcribe_far_forbidden(app_far) -> None:
    client = TestClient(app_far)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()), headers=_auth())
    assert resp.status_code == 403  # far mode, no X-RSSI → far
    assert resp.json()["error"]["code"] == "forbidden"


# --- validation -------------------------------------------------------------


def test_missing_audio_field_400(app_near) -> None:
    client = TestClient(app_near)
    # No multipart body at all.
    resp = client.post("/voice/transcribe", headers=_auth())
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"
    # Wrong field name.
    resp = client.post(
        "/voice/transcribe",
        files={"not_audio": ("clip.wav", _tiny_wav(), "audio/wav")},
        headers=_auth(),
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


def test_disallowed_content_type_400(app_near) -> None:
    client = TestClient(app_near)
    resp = client.post(
        "/voice/transcribe",
        files={"audio": ("evil.txt", b"not audio at all", "text/plain")},
        headers=_auth(),
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


def test_oversize_413(app_near) -> None:
    from server.main import MAX_VOICE_AUDIO_BYTES

    client = TestClient(app_near)
    big = b"\x00" * (MAX_VOICE_AUDIO_BYTES + 1)
    resp = client.post("/voice/transcribe", files=_wav_file(big), headers=_auth())
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "body_too_large"


# --- happy path + silence (STT mocked) --------------------------------------


def test_happy_path_mocked(app_near, monkeypatch) -> None:
    monkeypatch.setattr(
        "voice.stt.transcribe",
        lambda path, model_name="base": Transcription("hello buddy", 0.9),
    )
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav(0.1)), headers=_auth())
    assert resp.status_code == 200
    body = resp.json()
    assert body["text"] == "hello buddy"
    assert body["confidence"] == pytest.approx(0.9)
    assert body["duration_seconds"] == pytest.approx(0.1, abs=0.02)


def test_silence_shape_200_not_4xx(app_near, monkeypatch) -> None:
    """Empty/inaudible → 200 silence shape; the client decides to retry."""
    monkeypatch.setattr(
        "voice.stt.transcribe",
        lambda path, model_name="base": Transcription("", 0.0),
    )
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav(0.1)), headers=_auth())
    assert resp.status_code == 200
    body = resp.json()
    assert body["text"] == ""
    assert body["confidence"] == 0.0
    assert "duration_seconds" in body


def test_empty_upload_is_silence_shape(app_near) -> None:
    """Zero-byte upload answers the silence shape without touching STT."""
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(b""), headers=_auth())
    assert resp.status_code == 200
    assert resp.json() == {"text": "", "confidence": 0.0, "duration_seconds": 0.0}


# --- 501 when the backend is missing ----------------------------------------


def test_501_when_backend_missing_for_real(app_near) -> None:
    """faster-whisper is NOT installed here — the lazy import must 501."""
    pytest.importorskip("pytest")  # no-op guard; real assertion below
    try:
        import faster_whisper  # noqa: F401
        pytest.skip("faster-whisper installed — real-501 path not exercisable")
    except ImportError:
        pass
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()), headers=_auth())
    assert resp.status_code == 501
    assert resp.json()["error"]["code"] == "not_implemented"


def test_501_when_import_monkeypatched(app_near, monkeypatch) -> None:
    """Monkeypatched import failure maps to 501, never a 500 traceback."""
    import voice.stt as stt_mod

    def _boom(path, model_name="base"):
        raise RuntimeError("faster-whisper not installed — run: pip install -e .[voice]")

    monkeypatch.setattr(stt_mod, "transcribe", _boom)
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()), headers=_auth())
    assert resp.status_code == 501
    assert resp.json()["error"]["code"] == "not_implemented"


# --- hygiene: no temp leftovers, no events ----------------------------------


def test_no_temp_leftovers(app_near, monkeypatch) -> None:
    monkeypatch.setattr(
        "voice.stt.transcribe",
        lambda path, model_name="base": Transcription("hi", 0.8),
    )
    assert _stt_leftovers() == []
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()), headers=_auth())
    assert resp.status_code == 200
    assert _stt_leftovers() == []


def test_no_temp_leftovers_on_501(app_near, monkeypatch) -> None:
    """The 501 path also cleans up: force the backend failure explicitly so
    this holds whether or not faster-whisper is installed here."""
    import voice.stt as stt_mod

    def _boom(path, model_name="base"):
        raise RuntimeError("faster-whisper not installed — run: pip install -e .[voice]")

    monkeypatch.setattr(stt_mod, "transcribe", _boom)
    assert _stt_leftovers() == []
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()), headers=_auth())
    assert resp.status_code == 501
    assert _stt_leftovers() == []


def test_transcript_never_reaches_events(app_near, monkeypatch, tmp_path) -> None:
    """The endpoint emits no events — a marker transcript stays out of the log."""
    monkeypatch.setattr(
        "voice.stt.transcribe",
        lambda path, model_name="base": Transcription(f"please delete {MARKER} now", 0.95),
    )
    client = TestClient(app_near)
    resp = client.post("/voice/transcribe", files=_wav_file(_tiny_wav()), headers=_auth())
    assert resp.status_code == 200
    assert MARKER in resp.json()["text"]
    log = tmp_path / "events.jsonl"
    if log.exists():
        assert MARKER not in log.read_text(encoding="utf-8")
