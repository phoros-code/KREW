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


@dataclass
class ShellConfig:
    allowlist: list[str] = field(default_factory=list)
    denylist: list[str] = field(default_factory=list)


@dataclass
class FilesConfig:
    workspace_root: str = "~/buddy-workspace"
    allow_outside_workspace: bool = False


@dataclass
class WebSearchConfig:
    backend: str = "duckduckgo"
    searxng_url: str = ""


@dataclass
class AgentLimits:
    max_plan_steps: int = 20
    max_recursion_depth: int = 2
    tool_timeout_seconds: int = 30


@dataclass
class ToolsConfig:
    shell: ShellConfig = field(default_factory=ShellConfig)
    files: FilesConfig = field(default_factory=FilesConfig)
    web_search: WebSearchConfig = field(default_factory=WebSearchConfig)
    agent_limits: AgentLimits = field(default_factory=AgentLimits)


def load_models_config(path: str | Path | None = None) -> ModelsConfig:
    data = _load_yaml(Path(path).name if path else "models.yaml")
    ollama = data.get("ollama", data)
    return ModelsConfig(
        host=ollama.get("host", ModelsConfig.host),
        dev_model=ollama.get("dev_model", ModelsConfig.dev_model),
        target_model=ollama.get("target_model", ModelsConfig.target_model),
        fallback_model=ollama.get("fallback_model", ModelsConfig.fallback_model),
    )


def load_tools_config(path: str | Path | None = None) -> ToolsConfig:
    data = _load_yaml(Path(path).name if path else "tools.yaml")
    shell = data.get("shell", {})
    files = data.get("files", {})
    web = data.get("web_search", {})
    limits = data.get("agent_limits", {})
    return ToolsConfig(
        shell=ShellConfig(
            allowlist=list(shell.get("allowlist", [])),
            denylist=list(shell.get("denylist", [])),
        ),
        files=FilesConfig(
            workspace_root=files.get("workspace_root", "~/buddy-workspace"),
            allow_outside_workspace=bool(files.get("allow_outside_workspace", False)),
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
    )
