"""Optional per-user launchd service for keeping v2t warm between sessions."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from . import config

LABEL = "com.lucharo.voice2text"


def plist_path() -> Path:
    return Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"


def target() -> str:
    return f"gui/{os.getuid()}/{LABEL}"


def _launchctl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(
        ["launchctl", *args], capture_output=True, text=True, check=False
    )
    if check and result.returncode:
        raise RuntimeError(
            result.stderr.strip() or result.stdout.strip() or "launchctl failed"
        )
    return result


def loaded() -> bool:
    return _launchctl("print", target(), check=False).returncode == 0


def service_pid() -> int | None:
    """PID owned by launchd for this job, or None when the job is inactive."""
    result = _launchctl("print", target(), check=False)
    if result.returncode:
        return None
    for line in result.stdout.splitlines():
        key, separator, value = line.strip().partition(" = ")
        if key == "pid" and separator and value.isdigit():
            return int(value)
    return None


def plist_data() -> dict:
    environment = {
        "PATH": os.environ.get(
            "PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ),
        "V2T_HOME": str(config.home()),
    }
    if custom_config := os.environ.get("V2T_CONFIG"):
        environment["V2T_CONFIG"] = str(Path(custom_config).expanduser())
    log = config.run_dir() / "v2t.log"
    return {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, "-m", "v2t"],
        "RunAtLoad": True,
        "EnvironmentVariables": environment,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
        "Umask": 0o077,
    }


def _prepare_log() -> None:
    config.ensure_dirs()
    log = config.run_dir() / "v2t.log"
    if log.exists() and log.stat().st_size > 1_048_576:
        log.replace(log.with_suffix(".log.1"))
    log.touch()
    log.chmod(0o600)


def install() -> Path:
    if sys.platform != "darwin":
        raise SystemExit("the v2t service is macOS-only")
    running, managed = config.running_pid(), service_pid()
    if running is not None and running != managed:
        raise SystemExit(
            "v2t is already running directly; stop it before installing the service"
        )
    if loaded():
        _launchctl("bootout", target())
    _prepare_log()
    path = plist_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(plist_data(), stream)
        os.replace(temp_name, path)
    finally:
        Path(temp_name).unlink(missing_ok=True)
    start()
    return path


def start() -> None:
    path = plist_path()
    if not path.exists():
        raise SystemExit("service is not installed; run: v2t service install")
    _prepare_log()
    running, managed = config.running_pid(), service_pid()
    if running is not None and running == managed:
        return
    if running is not None:
        raise SystemExit(
            "v2t is already running directly; stop it before starting the service"
        )
    config.clear_last_error()
    if loaded():
        _launchctl("kickstart", target())
    else:
        _launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if config.running_pid() is not None:
            return
        if error := config.read_last_error():
            raise RuntimeError(error)
        time.sleep(0.1)
    raise RuntimeError(f"service did not start; check {config.run_dir() / 'v2t.log'}")


def stop() -> None:
    if service_pid() is not None:
        _launchctl("kill", "SIGTERM", target())


def uninstall() -> None:
    running, managed = config.running_pid(), service_pid()
    if running is not None and running != managed:
        raise SystemExit(
            "v2t is running directly; stop it before uninstalling the service"
        )
    if loaded():
        _launchctl("bootout", target())
    plist_path().unlink(missing_ok=True)


def status() -> str:
    if not plist_path().exists():
        return "not installed"
    running, managed = config.running_pid(), service_pid()
    if running is not None and running == managed:
        return "running"
    if running is not None:
        return "installed; v2t is running directly"
    return "loaded" if loaded() else "installed but unloaded"
