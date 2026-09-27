"""Tests for scripts/mic_check.py + scripts/download_voice_models.py.

Hardware-free: pyaudio is faked, downloads run against a local
http.server. The real mic path (record_sample without injection) is
never executed here — it is a human hardware gate (HARDWARE_VERIFICATION).
"""

from __future__ import annotations

import audioop
import struct
import threading
from functools import partial
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

import scripts.download_voice_models as dl
import scripts.mic_check as mic


# --- mic_check: pure parts with a fake pyaudio module ---


class _FakeStream:
    def __init__(self, audio, **kwargs):
        self._audio = audio

    def read(self, n, exception_on_overflow=False):
        return b"\x00\x01" * n  # n frames of mono 16-bit PCM

    def stop_stream(self):
        pass

    def close(self):
        pass


class _FakePyAudioModule:
    paInt16 = 8

    class PyAudio:
        def __init__(self, devices=None):
            self._devices = (
                devices
                if devices is not None
                else [
                    {"name": "Speakers", "maxInputChannels": 0, "defaultSampleRate": 44100.0},
                    {"name": "USB Mic", "maxInputChannels": 1, "defaultSampleRate": 16000.0},
                ]
            )

        def get_device_count(self):
            return len(self._devices)

        def get_device_info_by_index(self, i):
            return self._devices[i]

        def open(self, **kwargs):
            return _FakeStream(self, **kwargs)

        def terminate(self):
            pass


def test_list_inputs_filters_to_inputs() -> None:
    devices = mic.list_inputs(pyaudio_mod=_FakePyAudioModule)
    assert devices == [
        {"index": 1, "name": "USB Mic", "channels": 1, "default_rate": 16000}
    ]


def test_list_inputs_empty_when_no_mic() -> None:
    class _NoInputs(_FakePyAudioModule.PyAudio):
        def __init__(self):
            super().__init__(devices=[])

    mod = _FakePyAudioModule()
    mod.PyAudio = _NoInputs
    assert mic.list_inputs(pyaudio_mod=mod) == []


def test_rms_level_silence_vs_speech() -> None:
    assert mic.rms_level(b"\x00" * 3200) == 0.0
    assert mic.rms_level(b"") == 0.0
    loud = struct.pack("<1600h", *([1000, -1000] * 800))
    assert mic.rms_level(loud) == pytest.approx(audioop.rms(loud, 2))
    assert mic.rms_level(loud) > mic.SILENCE_RMS_WARN


def test_record_sample_uses_fake_device() -> None:
    pcm = mic.record_sample(1, pyaudio_mod=_FakePyAudioModule)
    # Production reads int(16000/1024 * seconds) full 1024-frame buffers.
    assert len(pcm) == int(16000 / 1024 * 1) * 1024 * 2
    assert mic.rms_level(pcm) > 0


def test_main_list_only_no_hardware(monkeypatch, capsys) -> None:
    monkeypatch.setattr(mic, "_load_pyaudio", lambda: _FakePyAudioModule)
    assert mic.main(["--list-only"]) == 0
    assert "USB Mic" in capsys.readouterr().out


def test_main_missing_pyaudio_fails_closed(monkeypatch) -> None:
    def _boom():
        raise RuntimeError("pyaudio not installed")

    monkeypatch.setattr(mic, "_load_pyaudio", _boom)
    assert mic.main(["--list-only"]) == 1


# --- download_voice_models: URL building + local-HTTP download ---


def test_model_urls_default() -> None:
    onnx, js = dl.model_urls()
    assert onnx.endswith("en/en_US/lessac/medium/en_US-lessac-medium.onnx")
    assert js == onnx + ".json"
    assert onnx.startswith("https://huggingface.co/rhasspy/piper-voices/resolve/main/")


def test_model_urls_bad_name() -> None:
    with pytest.raises(ValueError, match="must look like"):
        dl.model_urls("nonsense")


class _FileHandler(BaseHTTPRequestHandler):
    payload = b"x" * 100

    def do_GET(self):  # noqa: N802
        body = self.payload
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture()
def file_server(tmp_path):
    server = HTTPServer(("127.0.0.1", 0), _FileHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def test_download_writes_exact_bytes(tmp_path, file_server) -> None:
    dest = tmp_path / "model.onnx"
    size = dl.download(file_server + "/model.onnx", dest, timeout=10)
    assert size == 100
    assert dest.read_bytes() == b"x" * 100


def test_download_short_body_raises(tmp_path, file_server, monkeypatch) -> None:
    import urllib.request as _urlreq

    real_urlopen = _urlreq.urlopen

    class _LyingResp:
        status = 200
        headers = {"Content-Length": "9999"}

        def __init__(self, raw):
            self._raw = raw

        def read(self, n=-1):
            data, self._raw = self._raw[:n], self._raw[n:]
            return data

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fake_urlopen(req, timeout=None):
        with real_urlopen(req, timeout=timeout) as raw:
            return _LyingResp(raw.read())

    monkeypatch.setattr(_urlreq, "urlopen", fake_urlopen)
    with pytest.raises(RuntimeError, match="[Ss]hort download"):
        dl.download(file_server + "/model.onnx", tmp_path / "m.onnx", timeout=10)


def test_main_skips_existing_unless_forced(tmp_path, capsys) -> None:
    dest = tmp_path / f"{dl.DEFAULT_VOICE}.onnx"
    dest.write_bytes(b"cached")
    (tmp_path / f"{dl.DEFAULT_VOICE}.onnx.json").write_bytes(b"{}")
    assert dl.main(["--out-dir", str(tmp_path)]) == 0
    assert "SKIP" in capsys.readouterr().out
    assert dest.read_bytes() == b"cached"  # untouched without --force


def test_main_bad_voice_name() -> None:
    assert dl.main(["--voice", "nonsense"]) == 1


def test_scripts_have_main_argv() -> None:
    assert callable(mic.main) and callable(dl.main)
    assert mic.parse_args(["--list-only"]).list_only is True
    assert dl.parse_args([]).voice == dl.DEFAULT_VOICE
    assert Path(dl.parse_args([]).out_dir).name == "models"
