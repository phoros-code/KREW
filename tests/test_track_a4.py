"""Track A4 tests: agent-surface correctness + config truth + dep truth.

- SSRF guard + 1MB response ceiling (buddy_core/tools/web_search.py)
- Typed launch/list-apps plans with validation (buddy_core/orchestrator.py)
- Wake config as single source (voice/wake.py + config/models.yaml)
- fail_mode honored, "near" rejected at load (server/main.py)
- Script/config truth (serve.ps1, pair_device.py, gen_cert.py, CONFIG.md)
- Ephemeral reply.wav (voice/voice_loop.py)
"""

from __future__ import annotations

import importlib.util
import json
import socket as std_socket
from collections import deque
from pathlib import Path

import httpx
import pytest
import yaml

import buddy_core.orchestrator as orch
from buddy_core import config as config_mod
from buddy_core.config import AgentLimits, AppEntry, AppsConfig, ToolsConfig
from buddy_core.tools import web_search
from server.main import get_proximity, load_proximity_config
from voice import voice_loop, wake
from voice.stt import Transcription

REPO_ROOT = Path(__file__).resolve().parent.parent

_PUBLIC = [(std_socket.AF_INET, std_socket.SOCK_STREAM, 6, "", ("93.184.216.34", 0))]


def _public_dns(monkeypatch) -> None:
    monkeypatch.setattr("socket.getaddrinfo", lambda host, port, *a, **k: list(_PUBLIC))


class _FakeStream:
    """Minimal httpx.stream context manager over canned byte chunks."""

    def __init__(self, url: str, chunks: list[bytes], holder: dict):
        self._url = str(url)
        self._chunks = chunks
        self._holder = holder
        self._holder["consumed"] = 0

    def __enter__(self):
        self._holder["stream"] = self
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        pass

    @property
    def url(self):
        return httpx.URL(self._url)

    @property
    def encoding(self):
        return "utf-8"

    def iter_bytes(self, chunk_size: int = 65536):
        for chunk in self._chunks:
            self._holder["consumed"] += 1
            yield chunk


# --- 1. SSRF guard (literal IPs resolve without DNS — hermetic) ---


def test_fetch_blocks_rfc1918() -> None:
    with pytest.raises(ValueError, match="[Nn]on-public|Blocked"):
        web_search.fetch_page_text("http://192.168.1.1/")


def test_fetch_blocks_loopback() -> None:
    with pytest.raises(ValueError, match="[Nn]on-public|Blocked"):
        web_search.fetch_page_text("http://127.0.0.1:11434/")


def test_fetch_blocks_file_scheme() -> None:
    with pytest.raises(ValueError, match="[Ss]cheme"):
        web_search.fetch_page_text("file:///etc/passwd")


def test_fetch_blocks_metadata_ip() -> None:
    with pytest.raises(ValueError, match="[Nn]on-public|Blocked"):
        web_search.fetch_page_text("http://169.254.169.254/")


def test_fetch_blocks_hostname_resolving_private(monkeypatch) -> None:
    def fake_getaddrinfo(host, port, *a, **k):
        return [(std_socket.AF_INET, std_socket.SOCK_STREAM, 6, "", ("10.1.2.3", 0))]

    def boom(method, url, **kwargs):
        raise AssertionError("stream must not be called for a blocked host")

    monkeypatch.setattr("socket.getaddrinfo", fake_getaddrinfo)
    monkeypatch.setattr(httpx, "stream", boom)
    with pytest.raises(ValueError, match="[Nn]on-public"):
        web_search.fetch_page_text("http://internal.example/")


def test_fetch_blocks_redirect_to_private(monkeypatch) -> None:
    def fake_getaddrinfo(host, port, *a, **k):
        ip = "93.184.216.34" if host == "public.example" else "10.9.9.9"
        return [(std_socket.AF_INET, std_socket.SOCK_STREAM, 6, "", (ip, 0))]

    holder: dict = {}
    monkeypatch.setattr("socket.getaddrinfo", fake_getaddrinfo)
    monkeypatch.setattr(
        httpx,
        "stream",
        lambda method, url, **k: _FakeStream("http://10.9.9.9/x", [b"<p>hi</p>"], holder),
    )
    with pytest.raises(ValueError, match="[Nn]on-public"):
        web_search.fetch_page_text("https://public.example/")


def test_fetch_oversized_body_truncated_and_flagged(monkeypatch) -> None:
    _public_dns(monkeypatch)
    holder: dict = {}
    chunks = [b"a" * 65536 for _ in range(20)]  # 1.25MB total
    monkeypatch.setattr(
        httpx, "stream", lambda method, url, **k: _FakeStream(str(url), chunks, holder)
    )
    text = web_search.fetch_page_text("https://public.example/big")
    assert web_search.TRUNCATED_MARKER in text
    assert text.endswith(web_search.TRUNCATED_MARKER)
    assert len(text) <= 8000 + len("\n\n" + web_search.TRUNCATED_MARKER)
    # Cut off at the 1MB ceiling: 16 full 64KB chunks + the partial 17th.
    assert holder["consumed"] <= 17


# --- 2. Launch / list-apps through typed, validated plans ---


def _apps() -> AppsConfig:
    return AppsConfig(
        apps={"notepad": AppEntry(display="Notepad", launcher=r"C:\windows\system32\notepad.exe")}
    )


def test_launch_plan_validation_rejects_oversized(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr("buddy_core.orchestrator.load_apps_config", _apps)
    tiny = ToolsConfig()
    tiny.agent_limits = AgentLimits(max_plan_steps=0, max_recursion_depth=2, tool_timeout_seconds=5)
    monkeypatch.setattr("buddy_core.orchestrator.load_tools_config", lambda: tiny)
    launched: list = []
    monkeypatch.setattr(
        "buddy_core.tools.launch_app.launch", lambda *a, **k: launched.append(a)
    )
    result = orch.run("open notepad")
    assert not result.ok
    assert "Plan rejected" in result.output
    assert launched == []  # validation fired before anything launched
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert [e["type"] for e in events] == ["task_started", "task_failed"]


def test_launch_events_unchanged(monkeypatch, tmp_path) -> None:
    from buddy_core.tools.launch_app import LaunchResult

    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr("buddy_core.orchestrator.load_apps_config", _apps)
    monkeypatch.setattr(
        "buddy_core.tools.launch_app.launch",
        lambda key, cfg, tools: LaunchResult(ok=True, message="Started PID 42", pid=42),
    )
    result = orch.run("open notepad")
    assert result.ok
    assert result.output == "Launched Notepad."
    assert result.steps_taken == 1
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert [e["type"] for e in events] == ["task_started", "tool_call", "task_completed"]
    assert events[1]["tool"] == "launch_app"
    assert events[1]["args"] == {"app_key": "notepad"}
    assert events[2]["result"] == "Started PID 42"


def test_list_apps_events_unchanged(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr("buddy_core.orchestrator.load_apps_config", _apps)
    result = orch.run("list apps")
    assert result.ok
    assert "notepad" in result.output
    assert result.steps_taken == 1
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    assert [e["type"] for e in events] == ["task_started", "tool_call", "task_completed"]
    assert events[1]["tool"] == "list_apps"
    assert events[1]["args"] == {}


def test_list_apps_plan_validation_rejects_oversized(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(orch, "EVENT_LOG", tmp_path / "events.jsonl")
    monkeypatch.setattr("buddy_core.orchestrator.load_apps_config", _apps)
    tiny = ToolsConfig()
    tiny.agent_limits = AgentLimits(max_plan_steps=0, max_recursion_depth=2, tool_timeout_seconds=5)
    monkeypatch.setattr("buddy_core.orchestrator.load_tools_config", lambda: tiny)
    result = orch.run("list apps")
    assert not result.ok
    assert "Plan rejected" in result.output


# --- 6. Wake config is the single source ---


def test_wake_threshold_from_yaml_drives_detection(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        config_mod,
        "_load_yaml",
        lambda name: {
            "ollama": {},
            "wake": {"stand_in": "hey_buddy", "custom_model": str(tmp_path / "nope.onnx"), "threshold": 0.9},
        },
    )
    assert wake.get_wake_settings()[2] == 0.9
    weak = {"hey_buddy": deque([0.5] * wake._HISTORY, maxlen=wake._HISTORY)}
    strong = {"hey_buddy": deque([0.95] * wake._HISTORY, maxlen=wake._HISTORY)}
    assert wake._detect(weak, 0.9) is False
    assert wake._detect(strong, 0.9) is True


# --- 7. fail_mode honored; "near" rejected at load ---


def test_fail_mode_near_rejected_at_load(tmp_path, caplog) -> None:
    sec = tmp_path / "security.yaml"
    sec.write_text(
        yaml.safe_dump(
            {"proximity": {"mode": "lan_plus_bluetooth", "rssi_near_threshold": -60, "fail_mode": "near"}}
        ),
        encoding="utf-8",
    )
    with caplog.at_level("WARNING", logger="server.main"):
        cfg = load_proximity_config(sec)
    assert cfg["fail_mode"] == "far"
    assert any("fail_mode" in r.getMessage() for r in caplog.records)
    assert get_proximity(cfg, None) == "far"
    assert get_proximity(cfg, "garbage") == "far"


def test_fail_mode_defaults_far(tmp_path) -> None:
    sec = tmp_path / "security.yaml"
    sec.write_text(
        yaml.safe_dump({"proximity": {"mode": "lan_plus_bluetooth"}}), encoding="utf-8"
    )
    cfg = load_proximity_config(sec)
    assert cfg["fail_mode"] == "far"
    assert get_proximity(cfg, None) == "far"


# --- 8. Script / config truth ---


def _load_script(name: str):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / "scripts" / f"{name}.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_pair_device_port_reads_security_yaml(tmp_path, monkeypatch) -> None:
    pair = _load_script("pair_device")
    monkeypatch.chdir(tmp_path)
    assert pair.bind_port() == 8443  # absent file → hardcoded default
    (tmp_path / "config").mkdir()
    (tmp_path / "config" / "security.yaml").write_text(
        yaml.safe_dump({"network": {"bind_port": 9443}}), encoding="utf-8"
    )
    assert pair.bind_port() == 9443


def test_gen_cert_out_dir(tmp_path) -> None:
    gen = _load_script("gen_cert")
    assert gen.parse_args([]).out_dir == "certs"
    out = tmp_path / "tls"
    assert gen.parse_args(["--out-dir", str(out)]).out_dir == str(out)
    assert gen.main(["--out-dir", str(out)]) == 0
    assert (out / "dev-cert.pem").is_file()
    assert (out / "dev-key.pem").is_file()


def test_serve_ps1_reads_security_yaml() -> None:
    text = (REPO_ROOT / "scripts" / "serve.ps1").read_text(encoding="utf-8")
    for key in ("security.yaml", "cert_path", "key_path", "bind_host", "bind_port"):
        assert key in text
    for default in ("8443", "0.0.0.0", "dev-cert.pem", "dev-key.pem"):
        assert default in text


def test_config_md_matches_script_reality() -> None:
    text = (REPO_ROOT / "CONFIG.md").read_text(encoding="utf-8")
    assert "currently hardcodes" not in text
    assert "serve.ps1" in text
    assert "pair_device.py" in text


# --- 9. Ephemeral reply.wav ---


def _stub_voice(monkeypatch, heard: str = "hi", confidence: float = 0.9):
    seen: dict = {}

    def fake_speak(text, out, model_path=None):
        seen["out"] = Path(out)
        return Path(out)

    monkeypatch.setattr(
        "voice.stt.transcribe", lambda path, model_name="base": Transcription(heard, confidence)
    )
    monkeypatch.setattr("voice.tts.speak", fake_speak)
    monkeypatch.setattr(
        "buddy_core.orchestrator.run",
        lambda cmd, task_id=None, source="text": orch.TaskResult(ok=True, output="yo", task_id="t"),
    )
    return seen


def test_default_reply_leaves_no_file_in_cwd(monkeypatch, tmp_path) -> None:
    monkeypatch.chdir(tmp_path)
    assert voice_loop.LoopConfig().reply_wav is None
    seen = _stub_voice(monkeypatch)
    reply = voice_loop.handle_utterance(tmp_path / "u.wav")
    assert reply == "yo"
    assert not (tmp_path / "reply.wav").exists()  # nothing dropped in CWD
    assert seen["out"].name == "reply.wav"
    assert seen["out"].parent != tmp_path  # explicit temp path, not CWD


def test_explicit_reply_path_still_honored(monkeypatch, tmp_path) -> None:
    seen = _stub_voice(monkeypatch)
    keep = tmp_path / "keep.wav"
    reply = voice_loop.handle_utterance(
        tmp_path / "u.wav", voice_loop.LoopConfig(reply_wav=str(keep))
    )
    assert reply == "yo"
    assert seen["out"] == keep
