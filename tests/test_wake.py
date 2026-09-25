"""Wake-word wiring tests — no mic, no models, no audio needed.

The ``wake:`` section of config/models.yaml is the single source of truth
(word, custom model path, threshold); module fallbacks apply only when the
config file is missing. Detection is driven by the loaded values — these
tests pin that with non-default YAML, never with module constants.
"""

from collections import deque

from buddy_core import config as config_mod
from voice import wake


def _wake_yaml(monkeypatch, wake_section) -> None:
    """Point load_models_config at an in-memory models.yaml with/without wake."""
    data = {"ollama": {"host": "http://x"}}
    if wake_section is not None:
        data["wake"] = wake_section
    monkeypatch.setattr(config_mod, "_load_yaml", lambda name: data)


def test_resolve_returns_stand_in_when_custom_absent(monkeypatch, tmp_path) -> None:
    missing = tmp_path / "maxy.onnx"  # never created
    _wake_yaml(
        monkeypatch,
        {"stand_in": "alexa", "custom_model": str(missing), "threshold": 0.5},
    )
    assert wake.resolve_wake_models() == ["alexa"]


def test_resolve_returns_custom_path_when_file_exists(monkeypatch, tmp_path) -> None:
    fake_model = tmp_path / "maxy.onnx"
    fake_model.write_bytes(b"")  # existence only; never a real model
    _wake_yaml(
        monkeypatch,
        {"stand_in": "alexa", "custom_model": str(fake_model), "threshold": 0.5},
    )
    assert wake.resolve_wake_models() == [str(fake_model)]


def test_non_default_yaml_drives_detection(monkeypatch, tmp_path) -> None:
    """Loaded values (not module constants) drive detection: word + threshold."""
    _wake_yaml(
        monkeypatch,
        {"stand_in": "hey_buddy", "custom_model": str(tmp_path / "nope.onnx"), "threshold": 0.9},
    )
    stand_in, _model, threshold = wake.get_wake_settings()
    assert (stand_in, threshold) == ("hey_buddy", 0.9)
    # Custom word honored for the stand-in path (custom file absent).
    assert wake.resolve_wake_models() == ["hey_buddy"]
    # A 0.5 score would fire under the old hardcoded 0.5 threshold — with the
    # loaded 0.9 it must not; 0.95 must.
    weak = {stand_in: deque([0.5] * wake._HISTORY, maxlen=wake._HISTORY)}
    strong = {stand_in: deque([0.95] * wake._HISTORY, maxlen=wake._HISTORY)}
    assert wake._detect(weak, threshold) is False
    assert wake._detect(strong, threshold) is True


def test_missing_config_file_uses_fallback_defaults(monkeypatch) -> None:
    def _missing(name):
        raise FileNotFoundError(f"Missing required config file: {name}")

    monkeypatch.setattr(config_mod, "_load_yaml", _missing)
    assert wake.get_wake_settings() == ("alexa", wake._FALLBACK_CUSTOM_MODEL, 0.5)
    assert wake.resolve_wake_models() == ["alexa"]


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
