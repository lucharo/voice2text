"""v2t command line.

    v2t                 run push-to-talk (default)
    v2t bench           benchmark STT + cleanup models
    v2t config          show resolved config + paths   (--init to write a template)
    v2t status          running/idle line for the SwiftBar plugin
    v2t stop            stop a running v2t
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys

from . import config


def cmd_run(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="v2t", description="push-to-talk voice-to-text")
    p.add_argument("--config", help="path to a config.toml")
    p.add_argument("--backend", choices=["parakeet", "whisper"], help="override transcription backend")
    p.add_argument("--model", help="override STT model")
    p.add_argument("--cleanup-model", help="override Ollama cleanup model")
    p.add_argument("--no-cleanup", action="store_true", help="paste raw transcription, skip LLM cleanup")
    p.add_argument("--casual", action="store_true", help="light cleanup (punctuation + fillers only)")
    p.add_argument("--strict", action="store_true", help="full cleanup (restructures) — the default")
    p.add_argument("--pause-music", action="store_true", help="pause media while recording (needs nowplaying-cli)")
    a = p.parse_args(argv)

    if a.config:
        os.environ["V2T_CONFIG"] = a.config
    overrides = {
        "backend": a.backend,
        "stt_model": a.model,
        "cleanup_model": a.cleanup_model,
        "cleanup_enabled": False if a.no_cleanup else None,
        "mode": "casual" if a.casual else ("strict" if a.strict else None),
        "pause_music": True if a.pause_music else None,
    }
    cfg = config.load(overrides)

    from . import app  # lazy: needs audio + MLX, unlike the commands above

    if cfg.pause_music and not _which("nowplaying-cli"):
        from loguru import logger
        logger.warning("nowplaying-cli not found (brew install nowplaying-cli) — music pause disabled.")
        cfg.pause_music = False
    app.check_and_request_permissions()
    app.VoiceToText(cfg).run()
    return 0


def cmd_config(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="v2t config")
    p.add_argument("--init", action="store_true", help="write a commented config.toml if absent")
    p.add_argument("--path", action="store_true", help="print paths only")
    a = p.parse_args(argv)

    if a.init:
        print(f"wrote {config.write_default()}")
        return 0
    print(f"home:    {config.home()}")
    print(f"config:  {config.config_path()}{'' if config.config_path().exists() else '  (using defaults; v2t config --init to create)'}")
    print(f"history: {config.history_path()}")
    if not a.path:
        from dataclasses import asdict
        print("\n[effective config]")
        for k, v in asdict(config.load()).items():
            print(f"  {k} = {v!r}")
    return 0


def _status() -> dict | None:
    path = config.run_dir() / "status.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    try:
        os.kill(data["pid"], 0)  # signal 0 = liveness probe
    except ProcessLookupError:
        for f in ("v2t.pid", "status.json"):
            (config.run_dir() / f).unlink(missing_ok=True)
        return None
    except PermissionError:
        pass  # alive but owned by someone else
    return data


def cmd_status(argv: list[str]) -> int:
    s = _status()
    if s is None:
        print("idle")
    else:
        print(f"running\t{s['backend']}\t{s['model']}\t{s['mode']}")
    return 0


def cmd_stop(argv: list[str]) -> int:
    s = _status()
    if s is None:
        print("not running")
        return 1
    os.kill(s["pid"], signal.SIGTERM)
    print(f"stopped v2t (pid {s['pid']})")
    return 0


def cmd_bench(argv: list[str]) -> int:
    from . import bench
    return bench.main(argv)


def _which(name: str) -> bool:
    from shutil import which
    return which(name) is not None


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    table = {"bench": cmd_bench, "config": cmd_config, "status": cmd_status, "stop": cmd_stop}
    if argv and argv[0] in table:
        return table[argv[0]](argv[1:])
    return cmd_run(argv[1:] if argv and argv[0] == "run" else argv)


if __name__ == "__main__":
    sys.exit(main())
