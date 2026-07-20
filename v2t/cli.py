"""v2t command line.

v2t                 run push-to-talk (default)
v2t setup           guided first-run config (pick models, detect Ollama)
    v2t config          show resolved config + paths   (--init to write a template)
    v2t status          live state line (off / starting / idle / recording / …)
    v2t stop            stop a running v2t
    v2t service         install/control an optional launch-at-login service
    v2t swiftbar        install/update the bundled SwiftBar plugin
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
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
    p.add_argument(
        "--casual",
        action="store_true",
        help="light cleanup (punctuation + fillers only)",
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="full cleanup (restructures) — the default",
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
    app.check_and_request_permissions()
    app.VoiceToText(cfg).run()
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
mode = "strict"
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
    package = "voice2text[whisper]" if backend == "whisper" else "voice2text"
    print(f"run:  v2t   (install with: uv tool install {package})")
    return 0


def cmd_status(argv: list[str]) -> int:
    """For SwiftBar: state, STT, cleanup, mode, and any error detail."""
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
        for value in (state, stt, cleanup, mode, error)
    ]
    print("\t".join(fields))
    return 0


def cmd_stop(argv: list[str]) -> int:
    pid = config.running_pid()
    if pid is None:
        config.clear_status()
        print("not running")
        return 1
    os.kill(pid, signal.SIGTERM)
    print(f"stopped v2t (pid {pid})")
    return 0


def cmd_swiftbar(argv: list[str]) -> int:
    from shutil import copy2

    default_dir = Path(
        os.environ.get(
            "SWIFTBAR_PLUGIN_DIR",
            "~/Library/Application Support/SwiftBar/Plugins",
        )
    ).expanduser()
    parser = argparse.ArgumentParser(
        prog="v2t swiftbar", description="install/update the SwiftBar plugin"
    )
    parser.add_argument(
        "--dir", type=Path, default=default_dir, help="SwiftBar plugins directory"
    )
    args = parser.parse_args(argv)

    source = Path(__file__).resolve().parent.parent / "swiftbar" / "v2t.5s.sh"
    if not source.exists():
        raise SystemExit("bundled SwiftBar plugin is missing; reinstall voice2text")
    args.dir.mkdir(parents=True, exist_ok=True)
    destination = args.dir / source.name
    copy2(source, destination)
    destination.chmod(0o755)
    print(f"installed {destination}")
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
            print(f"installed and started {path}")
            print(f"service executable: {sys.executable}")
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
        "setup": cmd_setup,
        "config": cmd_config,
        "status": cmd_status,
        "stop": cmd_stop,
        "service": cmd_service,
        "swiftbar": cmd_swiftbar,
    }
    if argv and argv[0] in table:
        return table[argv[0]](argv[1:])
    return cmd_run(argv[1:] if argv and argv[0] == "run" else argv)


if __name__ == "__main__":
    sys.exit(main())
