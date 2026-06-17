"""Config + paths for v2t.

Everything lives under ~/.v2t (or $V2T_HOME, or $XDG_CONFIG_HOME/v2t):
    config.toml                  user settings
    history/transcriptions.jsonl every transcription + metadata
    run/status.json              live state for the SwiftBar plugin

Zero config works: the defaults below are the shipped behaviour
(Parakeet + Qwen3, MLX, strict cleanup).
"""

from __future__ import annotations

import json
import os
import tomllib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class Config:
    backend: str = "parakeet"          # parakeet | whisper
    stt_model: str = ""                # blank = the backend's own default
    cleanup_enabled: bool = True
    cleanup_engine: str = "mlx"        # mlx (in-process via mlx-lm) | ollama
    cleanup_model: str = ""            # blank = the engine's own default
    mode: str = "strict"               # strict | casual
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
    return Path(os.environ["V2T_CONFIG"]).expanduser() if "V2T_CONFIG" in os.environ else home() / "config.toml"


def history_path() -> Path:
    return home() / "history" / "transcriptions.jsonl"


def run_dir() -> Path:
    return home() / "run"


def read_status() -> dict | None:
    """The running v2t's status (pid, model, mode, state), or None. Cleans a stale file."""
    path = run_dir() / "status.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        pid = data["pid"]
    except (ValueError, KeyError, OSError):
        return None
    try:
        os.kill(pid, 0)  # signal 0 = liveness probe
    except ProcessLookupError:
        path.unlink(missing_ok=True)
        return None
    except PermissionError:
        pass  # alive but owned by someone else
    return data


# TOML section -> Config field. Flat dataclass, sectioned file: friendlier to edit.
_SECTIONS = {
    "transcription": {"backend": "backend", "model": "stt_model"},
    "cleanup": {"enabled": "cleanup_enabled", "engine": "cleanup_engine", "model": "cleanup_model", "mode": "mode"},
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
    return cfg


DEFAULT_TOML = """\
# v2t config — every key is optional; delete what you don't override.

[transcription]
backend = "parakeet"   # parakeet (default, MLX) | whisper (needs voice2text[whisper])
model = ""             # blank = backend default (parakeet-tdt-0.6b-v3 / whisper-large-v3-turbo)

[cleanup]
enabled = true
engine = "mlx"         # mlx (in-process via mlx-lm, default) | ollama
model = ""             # blank = engine default (Qwen3-4B-Instruct-2507-4bit / qwen3:4b-instruct-2507)
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
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(DEFAULT_TOML)
    return path


def append_history(record: dict) -> None:
    """Append one JSONL line with a UTC timestamp. Best-effort: never breaks a transcription."""
    path = history_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), **record}
    with path.open("a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


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
        assert line["clean"] == "Hello." and line["ts"].endswith("+00:00"), "history roundtrip"

        os.environ.pop("V2T_HOME")
        os.environ["XDG_CONFIG_HOME"] = d
        assert home() == Path(d) / "v2t", "XDG fallback"

    print("config.py: all checks passed")
