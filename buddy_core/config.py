"""Central config loader — nothing security- or behavior-relevant is hardcoded.

Reads ``config/*.yaml`` per CONFIG.md. Agents and tools take the loaded
objects instead of literal paths or thresholds (CONTRIBUTING.md).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = REPO_ROOT / "config"


def _load_yaml(name: str) -> dict[str, Any]:
    path = CONFIG_DIR / name
    if not path.exists():
        # Allow security.yaml to be absent until first-run pairing generates it.
        if name == "security.yaml":
            example = CONFIG_DIR / "security.yaml.example"
            if example.exists():
                return yaml.safe_load(example.read_text(encoding="utf-8")) or {}
            return {}
        raise FileNotFoundError(f"Missing required config file: {path}")
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


@dataclass
class ModelsConfig:
    host: str = "http://localhost:11434"
    dev_model: str = "qwen2.5:3b"
    target_model: str = "llama3.1:8b"
    fallback_model: str = "qwen2.5:3b"
    # Fast model for the voice loop (latency-sensitive). Text/API requests
    # default to target_model (quality); voice requests default here.
    voice_model: str = "qwen2.5:3b"
    # Agent framework (Track B2 decision gate): "direct" (default — plain
    # ollama.Client calls) or "crewai" (CrewAI crew summarizes research;
    # every other route stays direct). Unknown values fail closed to direct.
    framework: str = "direct"
    # Wake-word routing. stand_in is the openWakeWord pre-trained name used
    # until the custom model file exists; custom_model is its repo-relative
    # path; threshold is the detection score cutoff.
    wake_stand_in: str = "alexa"
    wake_custom_model: str = "voice/models/maxy.onnx"
    wake_threshold: float = 0.5


@dataclass
class ShellConfig:
    allowlist: list[str] = field(default_factory=list)
    denylist: list[str] = field(default_factory=list)


@dataclass
class FilesConfig:
    workspace_root: str = "~/buddy-workspace"


@dataclass
class WebSearchConfig:
    backend: str = "duckduckgo"
    searxng_url: str = ""


@dataclass
class AppEntry:
    display: str
    launcher: str


@dataclass
class AppsConfig:
    apps: dict[str, AppEntry] = field(default_factory=dict)


@dataclass
class AgentLimits:
    max_plan_steps: int = 20
    max_recursion_depth: int = 2
    tool_timeout_seconds: int = 30


@dataclass
class MemoryConfig:
    # Agent-state store (Track B3). Relative paths resolve under REPO_ROOT.
    path: str = "logs/memory.jsonl"
    cap: int = 500


@dataclass
class BrowserConfig:
    # Track B5: browser automation scope. Empty = deny-all (fail closed);
    # the operator opts in per-domain, e.g. ["example.com"] (covers
    # subdomains too). Even a listed host must resolve public per hop.
    allowed_domains: list[str] = field(default_factory=list)


@dataclass
class ToolsConfig:
    shell: ShellConfig = field(default_factory=ShellConfig)
    files: FilesConfig = field(default_factory=FilesConfig)
    web_search: WebSearchConfig = field(default_factory=WebSearchConfig)
    agent_limits: AgentLimits = field(default_factory=AgentLimits)
    memory: MemoryConfig = field(default_factory=MemoryConfig)
    browser: BrowserConfig = field(default_factory=BrowserConfig)


def load_models_config(path: str | Path | None = None) -> ModelsConfig:
    data = _load_yaml(Path(path).name if path else "models.yaml")
    ollama = data.get("ollama", data)
    agents = data.get("agents") or {}  # missing section -> direct (backwards compat)
    wake = data.get("wake") or {}  # missing section -> defaults (backwards compat)
    raw_framework = agents.get("framework", ModelsConfig.framework)
    framework = str(raw_framework or "").strip().lower()
    if framework != "crewai":
        # Fail closed: only the exact opt-in enables CrewAI; typos,
        # blanks, and legacy configs without the section stay direct.
        framework = "direct"
    return ModelsConfig(
        host=ollama.get("host", ModelsConfig.host),
        dev_model=ollama.get("dev_model", ModelsConfig.dev_model),
        target_model=ollama.get("target_model", ModelsConfig.target_model),
        fallback_model=ollama.get("fallback_model", ModelsConfig.fallback_model),
        voice_model=ollama.get("voice_model", ModelsConfig.voice_model),
        framework=framework,
        wake_stand_in=wake.get("stand_in", ModelsConfig.wake_stand_in),
        wake_custom_model=wake.get("custom_model", ModelsConfig.wake_custom_model),
        wake_threshold=float(wake.get("threshold", ModelsConfig.wake_threshold)),
    )


def load_tools_config(path: str | Path | None = None) -> ToolsConfig:
    data = _load_yaml(Path(path).name if path else "tools.yaml")
    shell = data.get("shell", {})
    files = data.get("files", {})
    web = data.get("web_search", {})
    limits = data.get("agent_limits", {})
    mem = data.get("memory", {})
    if not isinstance(mem, dict):
        mem = {}
    mem_path = mem.get("path", MemoryConfig.path)
    if not isinstance(mem_path, str) or not mem_path.strip():
        mem_path = MemoryConfig.path
    try:
        mem_cap = mem.get("cap", MemoryConfig.cap)
        if isinstance(mem_cap, bool):
            raise ValueError("bool cap")
        mem_cap = int(mem_cap)
    except (TypeError, ValueError):
        mem_cap = MemoryConfig.cap
    if mem_cap < 1:
        mem_cap = MemoryConfig.cap
    browser = data.get("browser", {})
    if not isinstance(browser, dict):
        browser = {}
    raw_domains = browser.get("allowed_domains", [])
    if not isinstance(raw_domains, list):
        raw_domains = []
    allowed_domains = [d.strip() for d in raw_domains if isinstance(d, str) and d.strip()]
    # NOTE (review N4): there is intentionally NO automation.enabled key.
    # An earlier revision had one that nothing read — a toggle that changes
    # nothing is false assurance. focus_check is read-only and always
    # available; type_text/press_keys are consent-gated stubs regardless.
    # If a future typing track needs a kill-switch, add it then WITH wiring.
    return ToolsConfig(
        shell=ShellConfig(
            allowlist=list(shell.get("allowlist", [])),
            denylist=list(shell.get("denylist", [])),
        ),
        files=FilesConfig(
            workspace_root=files.get("workspace_root", "~/buddy-workspace"),
        ),
        web_search=WebSearchConfig(
            backend=web.get("backend", "duckduckgo"),
            searxng_url=web.get("searxng_url", ""),
        ),
        agent_limits=AgentLimits(
            max_plan_steps=int(limits.get("max_plan_steps", 20)),
            max_recursion_depth=int(limits.get("max_recursion_depth", 2)),
            tool_timeout_seconds=int(limits.get("tool_timeout_seconds", 30)),
        ),
        memory=MemoryConfig(path=mem_path, cap=mem_cap),
        browser=BrowserConfig(allowed_domains=allowed_domains),
    )


def load_apps_config(path: str | Path | None = None) -> AppsConfig:
    data = _load_yaml(Path(path).name if path else "apps.yaml")
    apps = data.get("apps", data)
    registry: dict[str, AppEntry] = {}
    for key, entry in apps.items():
        if not isinstance(entry, dict) or not entry.get("launcher"):
            continue
        registry[str(key)] = AppEntry(
            display=str(entry.get("display", key)),
            launcher=str(entry["launcher"]),
        )
    return AppsConfig(apps=registry)
