"""Config + paths for v2t.

Everything lives under ~/.v2t (or $V2T_HOME, or $XDG_CONFIG_HOME/v2t):
    config.toml                  user settings
    history/history.sqlite       every transcription + metadata, one row each
    run/status.json              live state for CLI and menu-bar clients

Zero config works: the defaults below are the shipped behaviour
(Parakeet + Qwen2.5, MLX, casual cleanup).
"""

from __future__ import annotations

import fcntl
import json
import os
import socket
import sqlite3
import tempfile
import tomllib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class Config:
    backend: str = "parakeet"  # parakeet | whisper
    stt_model: str = ""  # blank = the backend's own default
    streaming_mode: str = "hacky"  # off | hacky (parakeet only; see backends.STREAM_*)
    cleanup_enabled: bool = True
    cleanup_engine: str = "mlx"  # mlx (in-process via mlx-lm) | ollama
    cleanup_model: str = ""  # blank = the engine's own default
    mode: str = "casual"  # casual (default) | strict
    hotkey: str = "fn"
    sample_rate: int = 16000
    pause_music: bool = False
    save_history: bool = True
    keep_last_audio: bool = True  # run/last-recording.wav, overwritten each time
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
    """The SQLite history: one row per dictation or file transcription."""
    return home() / "history" / "history.sqlite"


def legacy_history_path() -> Path:
    """The JSONL history written before the database; imported into it once."""
    return home() / "history" / "transcriptions.jsonl"


def run_dir() -> Path:
    return home() / "run"


def last_audio_path() -> Path:
    """The most recent recording's audio, kept so a cut transcription can be redone."""
    return run_dir() / "last-recording.wav"


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
    "transcription": {
        "backend": "backend",
        "model": "stt_model",
        "streaming_mode": "streaming_mode",
    },
    "cleanup": {
        "enabled": "cleanup_enabled",
        "engine": "cleanup_engine",
        "model": "cleanup_model",
        "mode": "mode",
    },
    "hotkey": {"key": "hotkey"},
    "audio": {"sample_rate": "sample_rate"},
    "behavior": {
        "pause_music": "pause_music",
        "save_history": "save_history",
        "keep_last_audio": "keep_last_audio",
    },
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
        "streaming_mode": {"off", "hacky"},
        "hotkey": {"fn", "cmd_r", "cmd_l", "alt_r", "alt_l", "ctrl_r", "ctrl_l"},
    }
    for field, allowed in choices.items():
        value = getattr(cfg, field)
        if value not in allowed:
            raise SystemExit(
                f"invalid {field} {value!r}; choose: {', '.join(sorted(allowed))}"
            )
    if not isinstance(cfg.sample_rate, int) or cfg.sample_rate <= 0:
        raise SystemExit("audio.sample_rate must be a positive integer")
    for field in ("cleanup_enabled", "pause_music", "save_history", "keep_last_audio"):
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
streaming_mode = "hacky"  # hacky (default): transcribe while the hotkey is held, parakeet only | off

[cleanup]
enabled = true
engine = "mlx"         # mlx (in-process via mlx-lm, default) | ollama
model = ""             # blank = engine default (Qwen3.5-2B-4bit / qwen3:4b-instruct-2507)
mode = "casual"        # casual (punctuation + fillers only, default) | strict (restructures)

[hotkey]
key = "fn"             # fn (the 🌐 key, bottom-left) | cmd_r | cmd_l | alt_r | alt_l | ctrl_r | ctrl_l

[audio]
sample_rate = 16000

[behavior]
pause_music = false
save_history = true    # one row per transcription in history/history.sqlite
keep_last_audio = true # keep the last recording's audio at run/last-recording.wav (v2t transcribe it if a dictation came out cut)

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


# --- history: one big table, one row per dictation or file transcription ----
# The tuple is the whole schema. A new column is appended here and added to an
# existing database on its next open; booleans are 0/1; `extra` holds, as JSON,
# whatever a writer sent that has no column yet.
HISTORY_COLUMNS: tuple[tuple[str, str], ...] = (
    ("ts", "TEXT NOT NULL"),  # UTC, ISO 8601
    ("trigger", "TEXT"),  # hold | latched | file
    ("source", "TEXT"),  # the audio file, for `v2t transcribe`
    ("device", "TEXT"),  # input device the recording came from
    ("sample_rate", "INTEGER"),
    ("audio_s", "REAL"),
    ("rms", "REAL"),  # level over the whole recording, full scale = 1
    ("peak", "REAL"),
    ("zero_frac", "REAL"),  # share of exactly-zero samples (a dead input)
    ("loud_frac", "REAL"),  # share of 100 ms frames with speech-level sound
    ("level_warning", "TEXT"),  # what the user was warned about, if anything
    ("backend", "TEXT"),
    ("model", "TEXT"),
    ("streamed", "INTEGER"),
    ("stt_s", "REAL"),
    ("cleanup_engine", "TEXT"),
    ("cleanup_model", "TEXT"),
    ("mode", "TEXT"),
    ("cleanup_chunks", "INTEGER"),
    ("cleanup_guarded", "INTEGER"),  # chunks pasted raw: length changed too much
    ("cleanup_limited", "INTEGER"),  # chunks pasted raw: hit the token limit
    ("cleanup_s", "REAL"),
    ("replacements", "INTEGER"),  # dictionary replacements that fired
    ("paste_s", "REAL"),
    ("raw", "TEXT"),
    ("clean", "TEXT"),
    ("outcome", "TEXT"),  # pasted | printed | error: <reason>
    ("host", "TEXT"),
    ("version", "TEXT"),
    ("extra", "TEXT"),  # JSON
)
HISTORY_BOOLS = frozenset({"streamed"})


def _history_db() -> sqlite3.Connection:
    """The history database, created (and the old JSONL imported) on first use."""
    path = history_path()
    _private_dir(path.parent)
    con = sqlite3.connect(path)
    path.chmod(0o600)  # journal files inherit the database's mode
    con.row_factory = sqlite3.Row
    con.execute(
        "CREATE TABLE IF NOT EXISTS transcriptions (id INTEGER PRIMARY KEY, "
        + ", ".join(f"{name} {kind}" for name, kind in HISTORY_COLUMNS)
        + ")"
    )
    con.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    present = {row["name"] for row in con.execute("PRAGMA table_info(transcriptions)")}
    for name, kind in HISTORY_COLUMNS:
        if name not in present:  # a column added since this database was made
            kind = kind.replace(" NOT NULL", "")
            con.execute(f"ALTER TABLE transcriptions ADD COLUMN {name} {kind}")
    con.commit()
    _import_legacy_history(con)
    return con


def _import_legacy_history(con: sqlite3.Connection) -> int:
    """Rows from the pre-database JSONL, once. The file itself is left alone.

    The rows and the `legacy_imported` marker land in one write transaction, so
    a crash midway leaves nothing behind and the next open imports again, and a
    second process opening at the same time waits for the lock and then finds
    the marker.
    """
    marker = "SELECT value FROM meta WHERE key = 'legacy_imported'"
    if con.execute(marker).fetchone():
        return 0
    con.execute("BEGIN IMMEDIATE")
    try:
        if con.execute(marker).fetchone():
            con.execute("COMMIT")
            return 0
        count = 0
        path = legacy_history_path()
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict) or not record.get("ts"):
                    continue
                record.setdefault("trigger", "file" if record.get("source") else "hold")
                record.setdefault(
                    "outcome", "printed" if record.get("source") else "pasted"
                )
                _insert_history(con, record)
                count += 1
        con.execute(
            "INSERT INTO meta (key, value) VALUES ('legacy_imported', ?)", (str(count),)
        )
        con.execute("COMMIT")
    except BaseException:
        con.execute("ROLLBACK")
        raise
    return count


def _insert_history(con: sqlite3.Connection, record: dict) -> None:
    known = [name for name, _kind in HISTORY_COLUMNS]
    row = {name: record[name] for name in known if name in record}
    extra = {k: v for k, v in record.items() if k not in known and k != "id"}
    if extra:
        row["extra"] = json.dumps(extra, ensure_ascii=False)
    for name in HISTORY_BOOLS:
        if row.get(name) is not None:
            row[name] = int(bool(row[name]))
    names = list(row)
    con.execute(
        f"INSERT INTO transcriptions ({', '.join(names)}) "
        f"VALUES ({', '.join('?' * len(names))})",
        [row[name] for name in names],
    )


def append_history(record: dict) -> None:
    """Add one row. `ts`, `host` and `version` are filled in when absent.

    Storage trouble surfaces as OSError, like the file it replaced.
    """
    from . import __version__

    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "host": socket.gethostname(),
        "version": __version__,
        **record,
    }
    try:
        con = _history_db()
        try:
            _insert_history(con, record)
            con.commit()
        finally:
            con.close()
    except sqlite3.Error as error:
        raise OSError(f"history database: {error}") from error


def replacements_fired(text: str, replacements: list[tuple[str, str]]) -> list[str]:
    """The `heard => written` entries that change `text`, applied in file order."""
    fired = []
    for heard, written in replacements:
        rewritten = apply_replacements(text, [(heard, written)])
        if rewritten != text:
            fired.append(f"{heard} => {written}")
        text = rewritten
    return fired


def dictionary_path() -> Path:
    return home() / "dictionary.txt"


DICTIONARY_HEADER = """\
# v2t dictionary — one entry per line. Two kinds:
#   Term                 a name, product or jargon the recogniser gets wrong;
#                        the cleanup model is told to spell it exactly like this
#   heard => written     an exact replacement applied after cleanup (case-insensitive)
# Lines starting with # are ignored. `v2t dictionary import-wispr` merges Wispr Flow's.
"""


def dictionary_mtime() -> float:
    """Modification time of dictionary.txt, or 0 when absent (cheap change check)."""
    try:
        return dictionary_path().stat().st_mtime
    except OSError:
        return 0.0


def read_dictionary() -> tuple[list[str], list[tuple[str, str]]]:
    """(terms, replacements) from dictionary.txt; missing file means both empty."""
    path = dictionary_path()
    if not path.exists():
        return [], []
    terms: list[str] = []
    replacements: list[tuple[str, str]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=>" in line:
            heard, _, written = line.partition("=>")
            if heard.strip() and written.strip():
                replacements.append((heard.strip(), written.strip()))
        else:
            terms.append(line)
    return terms, replacements


def write_dictionary(terms: list[str], replacements: list[tuple[str, str]]) -> Path:
    """Rewrite dictionary.txt privately: terms first, then replacements, deduped."""
    path = dictionary_path()
    _config_parent(path)
    seen: set[str] = set()
    lines = [DICTIONARY_HEADER]
    if path.exists():  # keep the user's own comments; the header is re-emitted
        header_lines = set(DICTIONARY_HEADER.splitlines())
        for line in path.read_text().splitlines():
            if line.lstrip().startswith("#") and line not in header_lines:
                lines.append(line)
    for term in terms:
        if term.lower() not in seen:
            seen.add(term.lower())
            lines.append(term)
    for heard, written in replacements:
        key = f"{heard.lower()} => {written.lower()}"
        if key not in seen:
            seen.add(key)
            lines.append(f"{heard} => {written}")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)
    return path


def apply_replacements(text: str, replacements: list[tuple[str, str]]) -> str:
    """Whole-word, case-insensitive `heard => written` substitutions."""
    import re

    for heard, written in replacements:
        text = re.sub(
            rf"(?<!\w){re.escape(heard)}(?!\w)",
            lambda _match, written=written: written,  # literal: no \1 or \g<> parsing
            text,
            flags=re.IGNORECASE,
        )
    return text


def read_history() -> list[dict]:
    """Every row, oldest first, without its empty columns."""
    if not history_path().exists() and not legacy_history_path().exists():
        return []
    con = _history_db()
    try:
        rows = con.execute("SELECT * FROM transcriptions ORDER BY id").fetchall()
    finally:
        con.close()
    records = []
    for row in rows:
        record = {key: row[key] for key in row.keys() if row[key] is not None}
        for name in HISTORY_BOOLS:
            if name in record:
                record[name] = bool(record[name])
        if "extra" in record:
            record = {**json.loads(record.pop("extra")), **record}
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
        assert load({"mode": None}).mode == "casual", "None override ignored"

        p = write_default()
        assert p.exists() and "qwen3" in p.read_text(), "template written"
        before = p.read_text()
        write_default()
        assert p.read_text() == before, "never clobbers existing config"
        # config.toml round-trips through the loader
        assert load().cleanup_engine == "mlx", "toml parsed"

        legacy_history_path().parent.mkdir(parents=True, exist_ok=True)
        legacy_history_path().write_text(
            '{"ts": "2026-01-01T00:00:00+00:00", "raw": "old", "clean": "Old."}\n'
            "not json\n"
        )
        append_history({"raw": "héllo", "clean": "Hello.", "streamed": True})
        rows = read_history()
        assert [r["clean"] for r in rows] == ["Old.", "Hello."], "import, then append"
        assert rows[0]["trigger"] == "hold" and rows[1]["streamed"] is True
        assert rows[1]["ts"].endswith("+00:00") and rows[1]["version"], "filled in"
        assert read_history() == rows, "the import happens once"

        os.environ.pop("V2T_HOME")
        os.environ["XDG_CONFIG_HOME"] = d
        assert home() == Path(d) / "v2t", "XDG fallback"

    print("config.py: all checks passed")
