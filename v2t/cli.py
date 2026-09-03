"""v2t command line.

v2t                 run push-to-talk (default)
v2t transcribe      transcribe existing audio files (no microphone)
v2t setup           guided first-run config (pick models, detect Ollama)
    v2t history         show or search past transcriptions
    v2t config          show resolved config + paths   (--init to write a template)
    v2t status          live state line (off / starting / idle / recording / …)
    v2t stop            stop a running v2t
    v2t menubar         install/open the optional native menu-bar app
    v2t service         start the menu app automatically at login
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

from . import config


def cmd_run(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="v2t", description="push-to-talk voice-to-text")
    p.add_argument("--config", help="path to a config.toml")
    p.add_argument(
        "--backend",
        choices=["parakeet", "whisper"],
        help="override transcription backend",
    )
    p.add_argument("--model", help="override STT model")
    p.add_argument(
        "--cleanup-engine", choices=["mlx", "ollama"], help="override cleanup engine"
    )
    p.add_argument("--cleanup-model", help="override cleanup model")
    p.add_argument(
        "--no-cleanup",
        action="store_true",
        help="paste raw transcription, skip LLM cleanup",
    )
    cleanup_mode = p.add_mutually_exclusive_group()
    cleanup_mode.add_argument(
        "--casual",
        action="store_true",
        help="light cleanup (punctuation + fillers only) — the default",
    )
    cleanup_mode.add_argument(
        "--strict",
        action="store_true",
        help="full cleanup (restructures, removes false starts)",
    )
    p.add_argument(
        "--pause-music",
        action="store_true",
        help="pause media while recording (needs nowplaying-cli)",
    )
    a = p.parse_args(argv)

    if a.config:
        os.environ["V2T_CONFIG"] = a.config
    overrides = {
        "backend": a.backend,
        "stt_model": a.model,
        "cleanup_engine": a.cleanup_engine,
        "cleanup_model": a.cleanup_model,
        "cleanup_enabled": False if a.no_cleanup else None,
        "mode": "casual" if a.casual else ("strict" if a.strict else None),
        "pause_music": True if a.pause_music else None,
    }
    cfg = config.load(overrides)

    from . import app  # lazy: needs audio + MLX, unlike the commands above

    if cfg.pause_music and not _which("nowplaying-cli"):
        from loguru import logger

        logger.warning(
            "nowplaying-cli not found (brew install nowplaying-cli) — music pause disabled."
        )
        cfg.pause_music = False
    if os.environ.get("V2T_LAUNCH_CONTEXT") != "menubar":
        app.check_and_request_permissions()
    app.VoiceToText(cfg).run()
    return 0


@contextmanager
def _step(label: str):
    """A step that says what it is doing while it does it (design tenet: be communicative).

    Live elapsed seconds on an interactive stderr, one plain line when piped.
    """
    start = time.perf_counter()
    done = threading.Event()

    def tick():
        while not done.wait(0.1):
            sys.stderr.write(f"\r  {label}… {time.perf_counter() - start:5.1f}s\033[K")
            sys.stderr.flush()

    ticker = threading.Thread(target=tick, daemon=True) if sys.stderr.isatty() else None
    if ticker:
        ticker.start()
    else:
        print(f"  {label}…", file=sys.stderr)
    try:
        yield
    finally:
        done.set()
        elapsed = time.perf_counter() - start
        if ticker:
            ticker.join()
            sys.stderr.write(f"\r  {label} {elapsed:5.1f}s\033[K\n")
            sys.stderr.flush()
        else:  # piped: no live line, so close the step with its timing
            print(f"  {label} {elapsed:5.1f}s", file=sys.stderr)


def _audio_seconds(path: Path) -> float:
    """Clip length via ffprobe (ships with the ffmpeg both backends decode with); 0 if unknown."""
    try:
        probe = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return float(probe.stdout.strip())
    except (FileNotFoundError, ValueError):
        return 0.0


def _clock(seconds: float) -> str:
    return f"{int(seconds) // 60}:{int(seconds) % 60:02d}"


def _transcribe_files(cfg, paths: list[Path], clean: bool) -> int:
    from . import backends

    stt_label = backends.short_model(
        cfg.stt_model or backends.STT[cfg.backend].default_model
    )
    cleanup_label = backends.short_model(
        cfg.cleanup_model or backends.CLEANUP[cfg.cleanup_engine].default_model
    )
    banner = f"v2t transcribe · {stt_label}"
    if clean:
        banner += f" + {cleanup_label} ({cfg.mode})"
    print(
        f"{banner} · {len(paths)} file{'s' if len(paths) > 1 else ''}", file=sys.stderr
    )

    with _step(f"loading {stt_label}"):
        stt = backends.make_stt(cfg.backend, cfg.stt_model)
    cleaner = None
    if clean:
        with _step(f"loading {cleanup_label}"):
            cleaner = backends.make_cleanup(
                cfg.cleanup_engine, cfg.cleanup_model, cfg.ollama_url
            )

    chunks = []
    for index, path in enumerate(paths, 1):
        seconds = _audio_seconds(path)
        prefix = f"[{index}/{len(paths)}] " if len(paths) > 1 else ""
        length = f"  ({_clock(seconds)})" if seconds else ""
        print(f"{prefix}{path.name}{length}", file=sys.stderr)

        started = time.perf_counter()
        with _step("transcribing"):
            raw = stt.transcribe(str(path))
        stt_s = time.perf_counter() - started
        text, cleanup_s = raw, 0.0
        if cleaner is not None and raw:
            started = time.perf_counter()
            with _step("cleaning up"):
                try:
                    text = cleaner.cleanup(raw, cfg.mode)[0] or raw
                except Exception as error:  # a transcript in hand beats a failed run
                    print(
                        f"  cleanup failed ({error}) — keeping the raw text",
                        file=sys.stderr,
                    )
            cleanup_s = time.perf_counter() - started
        elapsed = stt_s + cleanup_s
        speed = f" · {seconds / elapsed:.0f}× realtime" if seconds and elapsed else ""
        print(
            f"  ✓ {len(text.split())} words in {elapsed:.1f}s{speed}", file=sys.stderr
        )
        chunks.append(f"# {path.name}\n{text}" if len(paths) > 1 else text)

        if cfg.save_history:
            try:
                config.append_history(
                    {
                        "source": str(path),
                        "audio_s": round(seconds, 2),
                        "backend": cfg.backend,
                        "model": cfg.stt_model
                        or backends.STT[cfg.backend].default_model,
                        "cleanup_engine": cfg.cleanup_engine if cleaner else None,
                        "cleanup_model": cleaner.model_id if cleaner else None,
                        "mode": cfg.mode,
                        "stt_s": round(stt_s, 3),
                        "cleanup_s": round(cleanup_s, 3),
                        "raw": raw,
                        "clean": text,
                    }
                )
            except OSError as error:
                print(f"  could not save history: {error}", file=sys.stderr)

    out = "\n\n".join(chunks).strip()
    print(out)
    if sys.stdout.isatty() and _which("pbcopy"):
        copied = subprocess.run(["pbcopy"], input=out, text=True, check=False)
        if copied.returncode == 0:
            print(f"✓ copied to clipboard ({len(out.split())} words)", file=sys.stderr)
        else:
            print("  clipboard copy failed (pbcopy)", file=sys.stderr)
    return 0


def cmd_transcribe(argv: list[str]) -> int:
    """Transcribe files on disk with the same local models — no microphone, no cloud."""
    p = argparse.ArgumentParser(
        prog="v2t transcribe",
        description="transcribe audio files to text, fully on-device",
    )
    p.add_argument(
        "files",
        nargs="+",
        metavar="AUDIO",
        help="audio/video files (anything ffmpeg reads)",
    )
    p.add_argument("--config", help="path to a config.toml")
    p.add_argument(
        "--backend",
        choices=["parakeet", "whisper"],
        help="override transcription backend",
    )
    p.add_argument("--model", help="override STT model")
    p.add_argument(
        "--clean",
        action="store_true",
        help="run the LLM cleanup pass (off by default — files transcribe verbatim)",
    )
    cleanup_mode = p.add_mutually_exclusive_group()
    cleanup_mode.add_argument(
        "--casual",
        action="store_true",
        help="cleanup, punctuation + fillers only (implies --clean)",
    )
    cleanup_mode.add_argument(
        "--strict",
        action="store_true",
        help="cleanup that also restructures (implies --clean)",
    )
    a = p.parse_args(argv)

    if a.config:
        os.environ["V2T_CONFIG"] = a.config
    clean = a.clean or a.casual or a.strict
    cfg = config.load(
        {
            "backend": a.backend,
            "stt_model": a.model,
            "cleanup_enabled": clean,
            "mode": "casual" if a.casual else ("strict" if a.strict else None),
        }
    )

    paths = [Path(f).expanduser() for f in a.files]
    if missing := [str(path) for path in paths if not path.is_file()]:
        raise SystemExit(f"v2t transcribe: no such file: {', '.join(missing)}")

    try:
        return _transcribe_files(cfg, paths, clean)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130


def _history_header(record: dict) -> str:
    """One line of metadata: local time, audio length, step timings, source file."""
    from datetime import datetime

    try:
        when = (
            datetime.fromisoformat(record["ts"]).astimezone().strftime("%Y-%m-%d %H:%M")
        )
    except (KeyError, TypeError, ValueError):
        when = "unknown time"
    parts = [when]
    if audio := record.get("audio_s"):
        parts.append(f"{_clock(audio)} audio")
    if stt := record.get("stt_s"):
        parts.append(f"stt {stt:.1f}s")
    if cleanup := record.get("cleanup_s"):
        parts.append(f"clean {cleanup:.1f}s")
    if source := record.get("source"):
        parts.append(Path(source).name)
    return " · ".join(parts)


def cmd_history(argv: list[str]) -> int:
    """Read the transcription history back without opening the JSONL by hand."""
    import json

    p = argparse.ArgumentParser(
        prog="v2t history", description="show or search past transcriptions"
    )
    p.add_argument(
        "term", nargs="?", help="only entries whose raw or clean text contains this"
    )
    p.add_argument(
        "-n",
        "--last",
        type=int,
        default=10,
        metavar="N",
        help="how many recent entries to show (default 10; 0 = all)",
    )
    p.add_argument("--raw", action="store_true", help="also show the raw transcription")
    p.add_argument(
        "--json", action="store_true", help="print the matching JSONL records instead"
    )
    a = p.parse_args(argv)

    records = config.read_history()
    if a.term:
        needle = a.term.lower()
        records = [
            r
            for r in records
            if needle in f"{r.get('raw', '')}\n{r.get('clean', '')}".lower()
        ]
    if a.last > 0:
        records = records[-a.last :]
    if not records:
        what = (
            f"no transcriptions match {a.term!r}" if a.term else "no transcriptions yet"
        )
        print(f"{what} ({config.history_path()})", file=sys.stderr)
        return 1
    if a.json:
        for record in records:
            print(json.dumps(record, ensure_ascii=False))
        return 0
    for index, record in enumerate(records):
        if index:
            print()
        print(_history_header(record))
        if a.raw:
            print(f"  raw:   {record.get('raw', '')}")
            print(f"  clean: {record.get('clean', '')}")
        else:
            print(f"  {record.get('clean', '')}")
    return 0


def cmd_config(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="v2t config")
    p.add_argument(
        "--init", action="store_true", help="write a commented config.toml if absent"
    )
    p.add_argument("--path", action="store_true", help="print paths only")
    a = p.parse_args(argv)

    if a.init:
        print(f"wrote {config.write_default()}")
        return 0
    print(f"home:    {config.home()}")
    print(
        f"config:  {config.config_path()}{'' if config.config_path().exists() else '  (using defaults; v2t config --init to create)'}"
    )
    print(f"history: {config.history_path()}")
    if not a.path:
        from dataclasses import asdict

        print("\n[effective config]")
        for k, v in asdict(config.load()).items():
            print(f"  {k} = {v!r}")
    return 0


_SETUP_TOML = """\
# Written by `v2t setup`. Run `v2t config` to see every option, or edit freely.

[transcription]
backend = "{backend}"
model = ""

[cleanup]
enabled = {enabled}
engine = "{engine}"
model = ""
mode = "casual"
"""


def _ask(prompt: str, options: list[tuple[str, str]], default: int = 0) -> str:
    """Numbered single-choice prompt. options = [(value, label)]; returns the value."""
    print(prompt)
    for i, (_v, label) in enumerate(options):
        print(f"  {i + 1}) {label}{'  (default)' if i == default else ''}")
    raw = input(f"  choice [{default + 1}]: ").strip()
    idx = int(raw) - 1 if raw.isdigit() and 1 <= int(raw) <= len(options) else default
    return options[idx][0]


def _yesno(prompt: str, default: bool = True) -> bool:
    raw = input(f"{prompt} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
    return default if not raw else raw.startswith("y")


def cmd_setup(argv: list[str]) -> int:
    from shutil import which

    path = config.config_path()
    print(f"v2t setup → {path}\n")
    if path.exists() and not _yesno(f"{path} exists. Overwrite?", default=False):
        print("keeping existing config.")
        return 0

    backend = _ask(
        "Transcription model:",
        [
            ("parakeet", "Parakeet — fast, multilingual (recommended)"),
            ("whisper", "Whisper — best for rare languages / accents"),
        ],
    )
    engine = "mlx"
    cleanup_enabled = _yesno(
        "\nAdd an LLM cleanup pass (punctuation, fillers)?", default=True
    )
    if cleanup_enabled:
        if which("ollama"):
            engine = _ask(
                "\nOllama detected. Cleanup engine:",
                [
                    ("mlx", "mlx-lm — in-process, no daemon (recommended)"),
                    ("ollama", "Ollama — reuse what you already run"),
                ],
            )
        else:
            print("\nNo Ollama found — using in-process mlx-lm for cleanup.")

    config.write_config(
        _SETUP_TOML.format(
            backend=backend, enabled=str(cleanup_enabled).lower(), engine=engine
        ),
        path,
    )
    print(f"\nwrote {path}")
    if cleanup_enabled and engine == "ollama":
        print("next: ollama pull qwen3:4b-instruct-2507")
    package = "'voice2text[whisper]'" if backend == "whisper" else "voice2text"
    print(f"run:  v2t   (install with: uv tool install {package})")
    return 0


def cmd_status(argv: list[str]) -> int:
    """Runtime state, models, mode, and any launch error."""
    from . import backends

    s = config.read_status()
    if s:
        state, stt, cleanup, mode, error = (
            s["state"],
            s["stt"],
            s["cleanup"],
            s["mode"],
            s.get("error", ""),
        )
    else:
        cfg = config.load()
        error = config.read_last_error()
        state = "launch-error" if error else "off"
        stt = backends.short_model(
            cfg.stt_model or backends.STT[cfg.backend].default_model
        )
        cleanup = (
            backends.short_model(
                cfg.cleanup_model or backends.CLEANUP[cfg.cleanup_engine].default_model
            )
            if cfg.cleanup_enabled
            else "off"
        )
        mode = cfg.mode
    fields = [
        " ".join(str(value).replace("|", "/").split())
        for value in (
            state,
            stt,
            cleanup,
            mode,
            error,
        )
    ]
    print("\t".join(fields))
    return 0


def cmd_stop(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="v2t stop")
    parser.add_argument(
        "--force", action="store_true", help="stop immediately instead of waiting"
    )
    args = parser.parse_args(argv)
    pid = config.running_pid()
    if pid is None:
        config.clear_status()
        print("not running")
        return 1
    os.kill(pid, signal.SIGKILL if args.force else signal.SIGTERM)
    action = "force-stopped" if args.force else "stopping"
    print(f"{action} v2t (pid {pid})")
    return 0


def cmd_menubar(argv: list[str]) -> int:
    from . import menubar

    parser = argparse.ArgumentParser(
        prog="v2t menubar", description="install or open the optional menu-bar app"
    )
    parser.add_argument(
        "action", nargs="?", choices=["install", "open"], default="install"
    )
    args = parser.parse_args(argv)
    if args.action == "install":
        path = menubar.install()
        print(f"installed {path}")
        menubar.open_app()
    else:
        menubar.open_app()
    return 0


def cmd_service(argv: list[str]) -> int:
    from . import service

    parser = argparse.ArgumentParser(prog="v2t service")
    parser.add_argument(
        "action", choices=["install", "start", "stop", "status", "uninstall"]
    )
    args = parser.parse_args(argv)
    if args.action == "status":
        print(service.status())
        return 0
    try:
        if args.action == "install":
            path = service.install()
            print(f"installed for login {path}")
            print(f"menu app: {service.menubar.app_path()}")
            return 0
        getattr(service, args.action)()
    except RuntimeError as error:
        raise SystemExit(f"service {args.action} failed: {error}") from error
    print(f"service {args.action} complete")
    return 0


def _which(name: str) -> bool:
    from shutil import which

    return which(name) is not None


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    table = {
        "transcribe": cmd_transcribe,
        "setup": cmd_setup,
        "history": cmd_history,
        "config": cmd_config,
        "status": cmd_status,
        "stop": cmd_stop,
        "service": cmd_service,
        "menubar": cmd_menubar,
    }
    if argv and argv[0] in table:
        return table[argv[0]](argv[1:])
    return cmd_run(argv[1:] if argv and argv[0] == "run" else argv)


if __name__ == "__main__":
    sys.exit(main())
