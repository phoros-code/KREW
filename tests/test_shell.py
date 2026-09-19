"""Tests for buddy_core/tools/shell.py — denylist wins, injection blocked."""

import sys

import pytest

from buddy_core.config import ShellConfig
from buddy_core.tools import shell
from buddy_core.tools.shell import ShellDenied

PY = sys.executable


@pytest.fixture()
def cfg() -> ShellConfig:
    return ShellConfig(
        allowlist=[f"{PY} *", "echo *", "git *"],
        denylist=["rm -rf*", "*format*", "*evil*"],
    )


def test_denylist_wins_over_allowlist(cfg: ShellConfig) -> None:
    # "echo *evil*" matches allowlist "echo *" AND denylist "*evil*" -> denied.
    with pytest.raises(ShellDenied):
        shell.check_allowed("echo something evil here", cfg)
    assert not shell.is_allowed("echo something evil here", cfg)


def test_denylist_case_insensitive(cfg: ShellConfig) -> None:
    with pytest.raises(ShellDenied):
        shell.check_allowed("echo FORMAT C:", cfg)


def test_rm_rf_blocked(cfg: ShellConfig) -> None:
    assert not shell.is_allowed("rm -rf /tmp/x", cfg)
    assert not shell.is_allowed("echo hi; rm -rf /", cfg)


def test_command_chaining_blocked(cfg: ShellConfig) -> None:
    for evil in (
        "echo hi; echo pwned",
        "echo hi && echo pwned",
        "echo hi || echo pwned",
        "echo hi | findstr hi",
        "echo $(whoami)",
        "echo `whoami`",
        "echo hi > out.txt",
    ):
        assert not shell.is_allowed(evil, cfg), evil


def test_not_in_allowlist_blocked(cfg: ShellConfig) -> None:
    assert not shell.is_allowed("curl http://example.com", cfg)
    with pytest.raises(ShellDenied):
        shell.check_allowed("curl http://example.com", cfg)


def test_empty_blocked(cfg: ShellConfig) -> None:
    with pytest.raises(ShellDenied):
        shell.check_allowed("   ", cfg)


def test_allowed_command_runs(cfg: ShellConfig) -> None:
    res = shell.run(f"{PY} -c \"print('hi-buddy')\"", cfg, timeout_seconds=30)
    assert res.ok
    assert "hi-buddy" in res.stdout


def test_blocked_command_never_executes(cfg: ShellConfig, tmp_path) -> None:
    # If this executed, the marker file would exist. It must not.
    marker = tmp_path / "pwned.txt"
    with pytest.raises(ShellDenied):
        shell.run(f"echo hi; echo x > {marker}", cfg)
    assert not marker.exists()
