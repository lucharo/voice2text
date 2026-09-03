"""Config + paths for v2t.

Everything lives under ~/.v2t (or $V2T_HOME, or $XDG_CONFIG_HOME/v2t):
    config.toml                  user settings
    history/transcriptions.jsonl every transcription + metadata
    run/status.json              live state for CLI and menu-bar clients

Zero config works: the defaults below are the shipped behaviour
(Parakeet + Qwen2.5, MLX, strict cleanup).
"""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
import tomllib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class Config:
    backend: str = "parakeet"  # parakeet | whisper
    stt_model: str = ""  # blank = the backend's own default
    cleanup_enabled: bool = True
    cleanup_engine: str = "mlx"  # mlx (in-process via mlx-lm) | ollama
    cleanup_model: str = ""  # blank = the engine's own default
    mode: str = "strict"  # strict | casual
    hotkey: str = "cmd_r"
    sample_rate: int = 16000
    pause_music: bool = False
    save_history: bool = True
    ollama_url: str = "http://localhost:11434"


def home() -> Path:
    """The v2t home directory. $V2T_HOME > $XDG_CONFIG_HOME/v2t > ~/.v2t."""
    if env := os.environ.get("V2T_HOME"):
        return Path(env).expanduser()
    if xdg := os.environ.get("XDG_CONFIG_HOME"):
        return Path(xdg).expanduser() / "v2t"
    return Path.home() / ".v2t"


def config_path() -> Path:
    return (
        Path(os.environ["V2T_CONFIG"]).expanduser()
        if "V2T_CONFIG" in os.environ
        else home() / "config.toml"
    )


def history_path() -> Path:
    return home() / "history" / "transcriptions.jsonl"


def run_dir() -> Path:
    return home() / "run"


def _private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def ensure_dirs() -> None:
    _private_dir(home())
    _private_dir(history_path().parent)
    _private_dir(run_dir())


def _config_parent(path: Path) -> None:
    """Create a config parent privately, without chmodding an existing custom directory."""
    if path.parent == home():
        _private_dir(path.parent)
        return
    existed = path.parent.exists()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not existed:
        path.parent.chmod(0o700)


def lock_path() -> Path:
    return run_dir() / "v2t.lock"


def acquire_instance_lock():
    """Hold the single-instance lock for as long as the returned file stays open."""
    ensure_dirs()
    handle = lock_path().open("a+")
    os.chmod(handle.name, 0o600)
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()))
    handle.flush()
    return handle


def running_pid() -> int | None:
    """PID holding the instance lock, or None when v2t is not running."""
    path = lock_path()
    if not path.exists():
        return None
    with path.open("a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.seek(0)
            raw = handle.read().strip()
            return int(raw) if raw.isdigit() and int(raw) > 1 else None
        fcntl.flock(handle, fcntl.LOCK_UN)
    return None


def write_status(data: dict) -> None:
    """Atomically write private runtime status for CLI and menu-bar clients."""
    directory = run_dir()
    fd, temp_name = tempfile.mkstemp(dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
        os.replace(temp_name, directory / "status.json")
    finally:
        Path(temp_name).unlink(missing_ok=True)


def clear_status() -> None:
    (run_dir() / "status.json").unlink(missing_ok=True)


def last_error_path() -> Path:
    return run_dir() / "last-error"


def write_last_error(message: str) -> None:
    """Remember a launch failure that happened before the runtime lock existed."""
    ensure_dirs()
    path = last_error_path()
    path.write_text(" ".join(message.split()))
    path.chmod(0o600)


def read_last_error() -> str:
    try:
        return last_error_path().read_text().strip()
    except OSError:
        return ""


def clear_last_error() -> None:
    last_error_path().unlink(missing_ok=True)


def read_status() -> dict | None:
    """The running v2t's status, or None. Cleans stale or malformed state."""
    path = run_dir() / "status.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        pid = data["pid"]
        if not isinstance(pid, int) or pid <= 1:
            raise ValueError("invalid pid")
    except (TypeError, ValueError, KeyError, OSError):
        path.unlink(missing_ok=True)
        return None
    if running_pid() != pid:
        path.unlink(missing_ok=True)
        return None
    return data


# TOML section -> Config field. Flat dataclass, sectioned file: friendlier to edit.
_SECTIONS = {
    "transcription": {"backend": "backend", "model": "stt_model"},
    "cleanup": {
        "enabled": "cleanup_enabled",
        "engine": "cleanup_engine",
        "model": "cleanup_model",
        "mode": "mode",
    },
    "hotkey": {"key": "hotkey"},
    "audio": {"sample_rate": "sample_rate"},
    "behavior": {"pause_music": "pause_music", "save_history": "save_history"},
    "ollama": {"url": "ollama_url"},
}


def load(overrides: dict | None = None) -> Config:
    """Defaults < config.toml < CLI overrides. Unknown keys are ignored, not fatal."""
    cfg = Config()
    path = config_path()
    if path.exists():
        data = tomllib.loads(path.read_text())
        for section, mapping in _SECTIONS.items():
            for key, field in mapping.items():
                if key in data.get(section, {}):
                    setattr(cfg, field, data[section][key])
    for field, value in (overrides or {}).items():
        if value is not None:
            setattr(cfg, field, value)
    _validate(cfg)
    return cfg


def _validate(cfg: Config) -> None:
    choices = {
        "backend": {"parakeet", "whisper"},
        "cleanup_engine": {"mlx", "ollama"},
        "mode": {"strict", "casual"},
        "hotkey": {"cmd_r", "cmd_l", "alt_r", "alt_l", "ctrl_r", "ctrl_l"},
    }
    for field, allowed in choices.items():
        value = getattr(cfg, field)
        if value not in allowed:
            raise SystemExit(
                f"invalid {field} {value!r}; choose: {', '.join(sorted(allowed))}"
            )
    if not isinstance(cfg.sample_rate, int) or cfg.sample_rate <= 0:
        raise SystemExit("audio.sample_rate must be a positive integer")
    for field in ("cleanup_enabled", "pause_music", "save_history"):
        if not isinstance(getattr(cfg, field), bool):
            raise SystemExit(f"{field} must be true or false")
    for field in ("stt_model", "cleanup_model", "ollama_url"):
        if not isinstance(getattr(cfg, field), str):
            raise SystemExit(f"{field} must be a string")


DEFAULT_TOML = """\
# v2t config — every key is optional; delete what you don't override.

[transcription]
backend = "parakeet"   # parakeet (default, MLX) | whisper (needs voice2text[whisper])
model = ""             # blank = backend default (parakeet-tdt-0.6b-v3 / whisper-large-v3-turbo)

[cleanup]
enabled = true
engine = "mlx"         # mlx (in-process via mlx-lm, default) | ollama
model = ""             # blank = engine default (Qwen2.5-1.5B-Instruct-4bit / qwen3:4b-instruct-2507)
mode = "strict"        # strict (restructures) | casual (punctuation + fillers only)

[hotkey]
key = "cmd_r"          # cmd_r | cmd_l | alt_r | alt_l | ctrl_r | ctrl_l

[audio]
sample_rate = 16000

[behavior]
pause_music = false
save_history = true    # append every transcription to history/transcriptions.jsonl

[ollama]
url = "http://localhost:11434"
"""


def write_default(path: Path | None = None) -> Path:
    """Write a commented template if absent. Never clobbers an existing file."""
    path = path or config_path()
    _config_parent(path)
    if not path.exists():
        path.write_text(DEFAULT_TOML)
    path.chmod(0o600)
    return path


def write_config(text: str, path: Path | None = None) -> Path:
    """Write an explicit user config privately, preserving custom parent permissions."""
    path = path or config_path()
    _config_parent(path)
    path.write_text(text)
    path.chmod(0o600)
    return path


def append_history(record: dict) -> None:
    """Append one private JSONL record."""
    path = history_path()
    _private_dir(path.parent)
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), **record}
    fd = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def read_history() -> list[dict]:
    """Every history record, oldest first. Malformed lines are skipped, not fatal."""
    path = history_path()
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


if __name__ == "__main__":
    # ponytail: one runnable check for the trust-boundary logic (paths + merge + io).
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        os.environ["V2T_HOME"] = d
        os.environ.pop("XDG_CONFIG_HOME", None)
        os.environ.pop("V2T_CONFIG", None)

        assert home() == Path(d), "V2T_HOME must win"
        assert load().backend == "parakeet", "default backend"
        assert load({"mode": "casual"}).mode == "casual", "override wins"
        assert load({"mode": None}).mode == "strict", "None override ignored"

        p = write_default()
        assert p.exists() and "qwen3" in p.read_text(), "template written"
        before = p.read_text()
        write_default()
        assert p.read_text() == before, "never clobbers existing config"
        # config.toml round-trips through the loader
        assert load().cleanup_engine == "mlx", "toml parsed"

        append_history({"raw": "héllo", "clean": "Hello."})
        line = json.loads(history_path().read_text().splitlines()[-1])
        assert line["clean"] == "Hello." and line["ts"].endswith("+00:00"), (
            "history roundtrip"
        )
        with history_path().open("a") as f:
            f.write("not json\n")
        assert [r["clean"] for r in read_history()] == ["Hello."], "skips bad lines"

        os.environ.pop("V2T_HOME")
        os.environ["XDG_CONFIG_HOME"] = d
        assert home() == Path(d) / "v2t", "XDG fallback"

    print("config.py: all checks passed")
