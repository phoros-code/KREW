"""Wake-word wiring tests — no mic, no models, no audio needed.

Covers Sprint 2.1 scaffolding: resolve_wake_models() stand-in vs custom
path selection, and the wake threshold default (0.5).
"""

from pathlib import Path

from buddy_core import config as config_mod
from voice import wake


def test_resolve_returns_stand_in_when_custom_absent(monkeypatch, tmp_path) -> None:
    missing = tmp_path / "maxy.onnx"  # never created
    monkeypatch.setattr(wake, "CUSTOM_WAKE_MODEL", missing)
    assert wake.resolve_wake_models() == [wake.DEFAULT_WAKE_WORD]
    assert wake.resolve_wake_models() == ["alexa"]


def test_resolve_returns_custom_path_when_file_exists(monkeypatch, tmp_path) -> None:
    fake_model: Path = tmp_path / "maxy.onnx"
    fake_model.write_bytes(b"")  # existence only; never a real model
    monkeypatch.setattr(wake, "CUSTOM_WAKE_MODEL", fake_model)
    assert wake.resolve_wake_models() == [str(fake_model)]


def test_wake_threshold_default_is_half() -> None:
    assert wake._THRESHOLD == 0.5
    assert config_mod.ModelsConfig().wake_threshold == 0.5
    assert config_mod.ModelsConfig().wake_stand_in == "alexa"
    assert config_mod.ModelsConfig().wake_custom_model == "voice/models/maxy.onnx"
    assert config_mod.WakeConfig().threshold == 0.5


def test_load_models_config_missing_wake_section_uses_defaults(monkeypatch) -> None:
    monkeypatch.setattr(
        config_mod, "_load_yaml", lambda name: {"ollama": {"host": "http://x"}}  # no "wake"
    )
    cfg = config_mod.load_models_config()
    assert cfg.wake_stand_in == "alexa"
    assert cfg.wake_custom_model == "voice/models/maxy.onnx"
    assert cfg.wake_threshold == 0.5


def test_load_models_config_reads_wake_section(monkeypatch) -> None:
    monkeypatch.setattr(
        config_mod,
        "_load_yaml",
        lambda name: {"ollama": {}, "wake": {"stand_in": "hey_jarvis", "custom_model": "x.onnx", "threshold": 0.7}},
    )
    cfg = config_mod.load_models_config()
    assert cfg.wake_stand_in == "hey_jarvis"
    assert cfg.wake_custom_model == "x.onnx"
    assert cfg.wake_threshold == 0.7
