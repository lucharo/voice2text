"""Is a newer v2t out, and how would this Mac upgrade to it?

The menu app's "Update to vX.Y.Z" row reads `v2t update --check --json`. It knows
the two halves v2t ships as:

- the engine: `uv tool install voice2text`, upgraded with `uv tool upgrade
  voice2text`. An editable or path install (a source checkout) and anything not
  installed by uv (pip, uvx, `uv run`) is left to whoever installed it.
- the menu app: the Homebrew cask in /Applications (`brew upgrade --cask
  voice2text`), or the copy `v2t menubar install` compiled into ~/Applications,
  which is rebuilt from the upgraded engine once the app has quit.

The latest release is read from PyPI, where every release is published first, at
most once a day; a failed read is retried after an hour and never replaces the
last good answer.
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import sys
import tempfile
import time
import tomllib
import urllib.request
from pathlib import Path
from typing import Callable

from . import __version__, config

PYPI_URL = "https://pypi.org/pypi/voice2text/json"
CHECK_EVERY_S = 24 * 3600
RETRY_AFTER_S = 3600
SYSTEM_APP = Path("/Applications/Voice2Text.app")
CASKROOMS = (Path("/opt/homebrew/Caskroom/voice2text"), Path("/usr/local/Caskroom/voice2text"))


def cache_path() -> Path:
    return config.run_dir() / "update-check.json"


def parse_version(text: str | None) -> tuple[int, ...] | None:
    """`0.5.16` as (0, 5, 16); None for anything else, pre-releases included."""
    parts = (text or "").split(".")
    if not parts or not all(part.isdigit() for part in parts):
        return None
    return tuple(int(part) for part in parts)


def newer(latest: str | None, current: str | None) -> bool:
    a, b = parse_version(latest), parse_version(current)
    return a is not None and b is not None and a > b


def fetch_pypi(timeout: float = 5.0) -> str:
    with urllib.request.urlopen(PYPI_URL, timeout=timeout) as response:
        return json.load(response)["info"]["version"]


def _read_cache() -> dict:
    try:
        data = json.loads(cache_path().read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_cache(data: dict) -> None:
    path = cache_path()
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def latest_release(now: float | None = None, fetch: Callable[[], str] | None = None) -> dict:
    """{"latest", "checked_at", and "error" after a failed read}, asking PyPI only
    when the last good answer is a day old and no failure happened in the last hour."""
    now = time.time() if now is None else now
    config.ensure_dirs()
    # The menu and a terminal may ask at once: one asks PyPI, the other reads its answer.
    with open(config.run_dir() / "update-check.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _latest_release(now, fetch)


def _latest_release(now: float, fetch: Callable[[], str] | None) -> dict:
    cached = _read_cache()
    checked_at, failed_at = cached.get("checked_at"), cached.get("failed_at")
    fresh = isinstance(checked_at, (int, float)) and now - checked_at < CHECK_EVERY_S
    resting = isinstance(failed_at, (int, float)) and now - failed_at < RETRY_AFTER_S
    if fresh or resting:
        return cached
    try:
        latest = (fetch or fetch_pypi)()
        if parse_version(latest) is None:
            raise ValueError(f"unexpected version {latest!r}")
    except Exception as error:  # offline, proxy, PyPI down: keep the last good answer
        cached.update(failed_at=now, error=str(error) or type(error).__name__)
        _write_cache(cached)
        return cached
    answer = {"latest": latest, "checked_at": now}
    _write_cache(answer)
    return answer


def _which(name: str) -> str | None:
    """`name` on PATH, or where uv's installer and Homebrew put it (the menu app's PATH is short)."""
    extra = [str(Path.home() / ".local" / "bin"), str(Path.home() / ".cargo" / "bin"),
             "/opt/homebrew/bin", "/usr/local/bin"]
    path = os.pathsep.join([os.environ.get("PATH", ""), *extra])
    return shutil.which(name, path=path)


def engine_route(prefix: Path | None = None) -> str:
    """`uv` for a uv tool install from an index, `uv-source` for one from a path,
    git URL or editable checkout, else `other`."""
    receipt = (prefix or Path(sys.prefix)) / "uv-receipt.toml"
    try:
        requirements = tomllib.loads(receipt.read_text())["tool"]["requirements"]
    except (OSError, KeyError, tomllib.TOMLDecodeError):
        return "other"
    for requirement in requirements:
        if requirement.get("name") == "voice2text":
            sourced = {"editable", "path", "directory", "git", "url"} & requirement.keys()
            return "uv-source" if sourced else "uv"
    return "other"


def app_route(bundle: Path | None, caskrooms: tuple[Path, ...] = CASKROOMS) -> str | None:
    """`cask`, `local` (`v2t menubar install`), `other` (a build folder, or a local
    build beside the cask's copy), or None when no app asked."""
    if bundle is None:
        return None
    resolved = bundle.expanduser().resolve()
    if resolved == SYSTEM_APP.resolve() and any(room.is_dir() for room in caskrooms):
        return "cask"
    if resolved == (Path.home() / "Applications" / "Voice2Text.app").resolve():
        # `v2t menubar install` refuses to rebuild beside the cask's copy, so a
        # rebuild there would quit the app and never reopen it
        cask_copy = (SYSTEM_APP / "Contents" / "MacOS" / "Voice2Text").is_file()
        return "other" if cask_copy else "local"
    return "other"


def installed_app() -> tuple[Path | None, str | None]:
    """The installed menu app and its version, as `v2t menubar open` finds it."""
    import plistlib

    from . import menubar

    if not menubar.installed():
        return None, None
    try:
        info = plistlib.loads((menubar.app_path() / "Contents" / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException):
        return menubar.app_path(), None
    return menubar.app_path(), info.get("CFBundleShortVersionString")


def check(
    app: Path | None = None,
    app_version: str | None = None,
    *,
    now: float | None = None,
    fetch: Callable[[], str] | None = None,
    prefix: Path | None = None,
    caskrooms: tuple[Path, ...] = CASKROOMS,
) -> dict:
    """What `v2t update --check --json` prints.

    `update` is true only when the commands bring something to `latest`:
    `commands` run in order while the app keeps running, then `restart` says
    what to restart: `engine` (SIGHUP), or `app`, which quits and runs
    `relaunch` once it has gone (it reopens or rebuilds the app).
    """
    release = latest_release(now, fetch)
    latest = release.get("latest")
    engine, menu = engine_route(prefix), app_route(app, caskrooms)
    uv, brew = _which("uv"), _which("brew")
    commands: list[list[str]] = []
    relaunch: list[str] = []
    engine_behind = newer(latest, __version__)
    app_behind = menu in ("cask", "local") and newer(latest, app_version)
    if engine == "uv" and uv and (engine_behind or (app_behind and menu == "local")):
        # the tool folder this engine lives in, which a bundle may have baked from a
        # custom UV_TOOL_DIR the app's environment no longer sets
        tools = str((prefix or Path(sys.prefix)).parent)
        commands.append(["/usr/bin/env", f"UV_TOOL_DIR={tools}", uv, "tool", "upgrade", "voice2text"])
        if menu == "local" and app is not None:
            # compiled from the engine's package, so rebuilt from the new one; a failed
            # build leaves the old bundle in place (menubar.build swaps only on success),
            # so reopen that rather than leave dictation stopped
            relaunch = ["/bin/sh", "-c", '"$1" -m v2t menubar install || /usr/bin/open "$2"',
                        "sh", sys.executable, str(app)]
    if menu == "cask" and app_behind and brew:
        commands.append([brew, "upgrade", "--cask", "voice2text"])
        relaunch = ["/usr/bin/open", str(SYSTEM_APP)]
    return {
        "engine_version": __version__,
        "app_version": app_version,
        "latest": latest,
        "checked_at": release.get("checked_at"),
        "error": release.get("error"),
        "engine_route": engine,
        "app_route": menu,
        "update": bool(commands),
        "commands": commands,
        "restart": "app" if relaunch else "engine",
        "relaunch": relaunch,
    }
