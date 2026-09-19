"""Tests for buddy_core/tools/files.py — traversal rejected before happy path."""

import os
from pathlib import Path

import pytest

from buddy_core.config import FilesConfig
from buddy_core.tools import files
from buddy_core.tools.files import FileAccessDenied


@pytest.fixture()
def cfg(tmp_path: Path) -> FilesConfig:
    return FilesConfig(workspace_root=str(tmp_path / "ws"), allow_outside_workspace=False)


def test_write_then_read_roundtrip(cfg: FilesConfig) -> None:
    files.write_text("notes/hello.txt", "hi buddy", cfg)
    assert files.read_text("notes/hello.txt", cfg) == "hi buddy"


def test_list_dir(cfg: FilesConfig) -> None:
    files.write_text("a.txt", "a", cfg)
    files.write_text("sub/b.txt", "b", cfg)
    assert files.list_dir(".", cfg) == ["a.txt", "sub"]


def test_dotdot_traversal_rejected(cfg: FilesConfig) -> None:
    with pytest.raises(FileAccessDenied):
        files.read_text("../outside.txt", cfg)
    with pytest.raises(FileAccessDenied):
        files.write_text("../../evil.txt", "x", cfg)


def test_absolute_path_escape_rejected(cfg: FilesConfig) -> None:
    # Absolute system paths must not be reachable through the tool.
    with pytest.raises(FileAccessDenied):
        files.read_text("C:/Windows/win.ini", cfg)
    with pytest.raises(FileAccessDenied):
        files.read_text("/etc/passwd", cfg)


def test_symlink_escape_rejected(cfg: FilesConfig, tmp_path: Path) -> None:
    root = Path(cfg.workspace_root).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    outside = tmp_path / "secret.txt"
    outside.write_text("top-secret", encoding="utf-8")
    link = root / "link.txt"
    try:
        link.symlink_to(outside)
    except OSError:
        pytest.skip("symlinks not permitted on this system")
    with pytest.raises(FileAccessDenied):
        files.read_text("link.txt", cfg)


def test_missing_file_raises_not_found(cfg: FilesConfig) -> None:
    with pytest.raises(FileNotFoundError):
        files.read_text("nope.txt", cfg)


def test_workspace_created_on_write(cfg: FilesConfig) -> None:
    assert not os.path.exists(Path(cfg.workspace_root).expanduser())
    files.write_text("x.txt", "x", cfg)
    assert files.read_text("x.txt", cfg) == "x"
