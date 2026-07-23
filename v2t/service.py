"""Optional per-user launchd service for keeping v2t warm between sessions."""

from __future__ import annotations

import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from . import config, menubar

LABEL = menubar.BUNDLE_ID
READY_STATES = {"idle", "recording", "transcribing", "cleaning"}
START_TIMEOUT = 120
STOP_TIMEOUT = 120
FORCE_TIMEOUT = 5


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


def engine_ready(menu_pid: int | None = None) -> bool:
    status = config.read_status()
    if not status or status.get("state") not in READY_STATES:
        return False
    if menu_pid is None:
        return True
    engine_pid = status.get("pid")
    return isinstance(engine_pid, int) and _is_child(engine_pid, menu_pid)


def _is_child(pid: int, parent_pid: int) -> bool:
    result = subprocess.run(
        ["ps", "-o", "ppid=", "-p", str(pid)],
        capture_output=True,
        text=True,
        check=False,
    )
    parent = result.stdout.strip()
    return parent.isdigit() and int(parent) == parent_pid


def owned_engine_pid(menu_pid: int) -> int | None:
    """Return the live v2t engine only when it is a child of this menu process."""
    engine_pid = config.running_pid()
    if engine_pid is not None and _is_child(engine_pid, menu_pid):
        return engine_pid
    result = subprocess.run(
        ["pgrep", "-P", str(menu_pid)],
        capture_output=True,
        text=True,
        check=False,
    )
    return next(
        (int(line) for line in result.stdout.splitlines() if line.strip().isdigit()),
        None,
    )


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def plist_data() -> dict:
    log = config.run_dir() / "v2t.log"
    return {
        "Label": LABEL,
        "ProgramArguments": [str(menubar.app_executable()), "--start"],
        "RunAtLoad": True,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
        "Umask": 0o077,
    }


def _prepare_log() -> None:
    config.ensure_dirs()
    log = config.run_dir() / "v2t.log"
    log.touch()
    log.chmod(0o600)


def install() -> Path:
    if sys.platform != "darwin":
        raise SystemExit("the v2t service is macOS-only")
    if not menubar.installed():
        raise SystemExit("menu app is not installed; run: v2t menubar install")
    if menubar.running() and service_pid() is None:
        raise SystemExit("quit Voice2Text before installing the login service")
    if config.running_pid() is not None and service_pid() is None:
        raise SystemExit(
            "v2t is already running outside the login service; stop it first"
        )
    if loaded():
        stop()
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
    _launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
    return path


def start() -> None:
    path = plist_path()
    if not path.exists():
        raise SystemExit("service is not installed; run: v2t service install")
    menu_pid = service_pid()
    if menu_pid is not None:
        if engine_ready(menu_pid):
            return
        engine_pid = config.running_pid()
        if engine_pid is not None and not _is_child(engine_pid, menu_pid):
            raise SystemExit(
                "v2t is running outside the login service; stop it first"
            )
    elif menubar.running():
        raise SystemExit("quit Voice2Text before starting the login service")
    if menu_pid is None and config.running_pid() is not None:
        raise SystemExit(
            "v2t is already running outside the login service; stop it first"
        )
    _prepare_log()
    menu_engine_pid = (
        owned_engine_pid(menu_pid) if menu_pid is not None else None
    )
    restarting = menu_pid is not None and menu_engine_pid is None
    if menu_pid is None or restarting:
        config.clear_last_error()
        if restarting:
            stop()
            _launchctl("kickstart", target())
        elif loaded():
            _launchctl("kickstart", target())
        else:
            _launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
    seen_service = menu_pid is not None and not restarting
    deadline = time.monotonic() + START_TIMEOUT
    while time.monotonic() < deadline:
        current_service = service_pid()
        if current_service is not None and engine_ready(current_service):
            return
        if error := config.read_last_error():
            raise RuntimeError(error)
        if current_service is not None:
            seen_service = True
        elif seen_service:
            raise RuntimeError(
                f"service stopped during startup; check {config.run_dir() / 'v2t.log'}"
            )
        time.sleep(0.1)
    if not seen_service:
        raise RuntimeError(
            f"service did not start; check {config.run_dir() / 'v2t.log'}"
        )
    raise RuntimeError(
        f"models did not become ready within {START_TIMEOUT}s; "
        f"check {config.run_dir() / 'v2t.log'}"
    )


def stop() -> None:
    menu_pid = service_pid()
    if menu_pid is None:
        return
    engine_pid = owned_engine_pid(menu_pid)
    if engine_pid is not None:
        deadline = time.monotonic() + STOP_TIMEOUT
        runtime = config.read_status()
        already_stopping = bool(
            runtime
            and runtime.get("pid") == engine_pid
            and runtime.get("state") == "stopping"
        )
        if not already_stopping:
            try:
                os.kill(engine_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        while time.monotonic() < deadline:
            if not _pid_alive(engine_pid):
                break
            time.sleep(0.1)
        else:
            try:
                os.kill(engine_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            force_deadline = time.monotonic() + FORCE_TIMEOUT
            while time.monotonic() < force_deadline and _pid_alive(engine_pid):
                time.sleep(0.1)
            if _pid_alive(engine_pid):
                raise RuntimeError(
                    f"engine did not stop; check {config.run_dir() / 'v2t.log'}"
                )
    _launchctl("kill", "SIGTERM", target())
    deadline = time.monotonic() + STOP_TIMEOUT
    while time.monotonic() < deadline:
        if service_pid() is None:
            return
        time.sleep(0.1)
    raise RuntimeError(f"service is still stopping; check {config.run_dir() / 'v2t.log'}")


def uninstall() -> None:
    if loaded():
        stop()
        _launchctl("bootout", target())
    plist_path().unlink(missing_ok=True)


def status() -> str:
    if not plist_path().exists():
        return "not installed"
    menu_pid = service_pid()
    engine_pid = config.running_pid()
    if menu_pid is not None:
        if engine_pid is not None and _is_child(engine_pid, menu_pid):
            return "running"
        if engine_pid is not None:
            return "menu running; v2t is running outside the login service"
        return "menu running; v2t off"
    if engine_pid is not None:
        return "installed; v2t is running outside the login service"
    return "loaded" if loaded() else "installed but unloaded"
