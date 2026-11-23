"""Time settings changes and Stop in a v2t engine, for two checkouts at once.

Not user-facing and not packaged: a maintainer benchmark for the in-place reload.
Each round starts a benchmark engine (engine.py, no keyboard listener) from every
checkout in turn, alternating which goes first, waits for it to be idle, then
changes three settings in its config.toml and sends SIGHUP after each, timing the
signal until the status file says idle with the new setting:

    cleanup  the cleanup model, Qwen3.5 0.8B <-> 2B
    speech   the transcription model, Parakeet v3 on Core ML <-> on MLX
    setting  a setting read per dictation, casual <-> strict

then sends SIGTERM and times it until the process exits. The start is timed twice:
"live" until the status first says idle (the hotkey listener starts right after;
since 0.6.1 that is before the cleanup model loads, #212) and "start" until it says
idle with no cleanup model still loading (`cleanup_loading`, which older engines
never set, so for them the two are the same). The start and Stop always run;
`--arms stop` runs only those, with the first speech and cleanup model (`--cleanup` picks another), so a scratch
folder needs just those two models. Every engine runs with
its own temporary V2T_HOME, and HOME / HF_HOME pointing at a scratch folder that
already holds the models (HF_HUB_OFFLINE=1), so nothing under ~ is read or written.
The 1-minute load is recorded with every timing.

    .venv/bin/python utils/reload_bench/bench.py --scratch DIR --rounds 6 \
        --checkout before=/path/to/main --checkout after=.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))

from v2t import config  # noqa: E402  (the config format both checkouts share)

CLEANUP = ("mlx-community/Qwen3.5-0.8B-4bit", "mlx-community/Qwen3.5-2B-4bit")
CLEANUP_LABEL = {CLEANUP[0]: "Qwen3.5-0.8B", CLEANUP[1]: "Qwen3.5-2B"}
SPEECH = (("parakeet-coreml", "parakeet-v3-coreml"), ("parakeet", "parakeet-v3"))
MODES = ("casual", "strict")
TIMEOUT_S = 300.0
ARMS = ("live", "start", "cleanup", "speech", "setting", "stop")


def status(home: Path) -> dict | None:
    try:
        return json.loads((home / "run" / "status.json").read_text())
    except (OSError, ValueError):
        return None


def wait_start(home: Path, expect: dict, proc: subprocess.Popen, since: float) -> tuple[float, float]:
    """Seconds from `since` until the status first says idle with `expect`'s fields (the
    hotkey goes live) and until it also says no cleanup model is still loading (Ready)."""
    live = None
    while time.perf_counter() - since < TIMEOUT_S:
        if proc.poll() is not None:
            raise RuntimeError(f"engine exited ({proc.returncode})")
        s = status(home)
        if s and s.get("state") == "idle" and all(s.get(k) == v for k, v in expect.items()):
            now = time.perf_counter() - since
            live = now if live is None else live
            if not s.get("cleanup_loading"):
                return live, now
        time.sleep(0.01)
    raise TimeoutError(f"not idle with {expect} after {TIMEOUT_S:.0f}s")


def wait_idle(home: Path, expect: dict, proc: subprocess.Popen, since: float) -> float:
    """Seconds from `since` until the status says idle with `expect`'s fields."""
    while time.perf_counter() - since < TIMEOUT_S:
        if proc.poll() is not None:
            raise RuntimeError(f"engine exited ({proc.returncode})")
        s = status(home)
        if s and s.get("state") == "idle" and all(s.get(k) == v for k, v in expect.items()):
            return time.perf_counter() - since
        time.sleep(0.01)
    raise TimeoutError(f"not idle with {expect} after {TIMEOUT_S:.0f}s")


def write(home: Path, pairs: list[tuple[str, str]]) -> None:
    # V2T_CONFIG wins over V2T_HOME, so both point at the temporary home
    os.environ["V2T_HOME"] = str(home)
    os.environ["V2T_CONFIG"] = str(home / "config.toml")
    config.set_values(pairs)


def run_checkout(name: str, source: Path, scratch: Path, rnd: int, log, arms: set[str],
                 cleanups: tuple[str, str]) -> list[dict]:
    home = Path(tempfile.mkdtemp(prefix=f"v2t-bench-{name}-", dir=scratch))
    cleanup, speech, mode = rnd % 2, rnd % 2, rnd % 2  # alternate the direction per round
    if "cleanup" not in arms:
        cleanup = 0
    if "speech" not in arms:
        speech = 0
    backend, stt_label = SPEECH[speech]
    write(home, [
        ("transcription.backend", backend),
        ("cleanup.model", cleanups[cleanup]),
        ("cleanup.mode", MODES[mode]),
    ])
    env = dict(
        os.environ,
        V2T_HOME=str(home),
        V2T_CONFIG=str(home / "config.toml"),
        HOME=str(scratch / "home"),
        HF_HOME=str(scratch / "hf"),
        HF_HUB_OFFLINE="1",
        V2T_LAUNCH_CONTEXT="menubar",
        PYTHONPATH=str(source),
    )
    out = open(scratch / f"engine-{name}.log", "a")
    out.write(f"\n=== round {rnd} {name} {source}\n")
    out.flush()
    t0 = time.perf_counter()
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "engine.py")], env=env, stdout=out, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, cwd=str(home),
    )
    rows = []

    def row(arm: str, seconds: float, direction: str) -> None:
        r = {"round": rnd, "checkout": name, "arm": arm, "direction": direction,
             "seconds": round(seconds, 3), "load1": round(os.getloadavg()[0], 2)}
        rows.append(r)
        log.write(json.dumps(r) + "\n")
        log.flush()
        print(json.dumps(r), flush=True)

    try:
        live, ready = wait_start(
            home, {"stt": stt_label, "cleanup": CLEANUP_LABEL[cleanups[cleanup]]}, proc, t0
        )
        row("live", live, "cold")
        row("start", ready, "cold")
        time.sleep(2)  # let the start's own work settle

        if "cleanup" in arms:
            new = cleanups[1 - cleanup]
            write(home, [("cleanup.model", new)])
            t = time.perf_counter()
            os.kill(proc.pid, signal.SIGHUP)
            row("cleanup", wait_idle(home, {"cleanup": CLEANUP_LABEL[new]}, proc, t),
                f"{CLEANUP_LABEL[cleanups[cleanup]]}->{CLEANUP_LABEL[new]}")
            time.sleep(2)

        if "speech" in arms:
            new_backend, new_label = SPEECH[1 - speech]
            write(home, [("transcription.backend", new_backend)])
            t = time.perf_counter()
            os.kill(proc.pid, signal.SIGHUP)
            row("speech", wait_idle(home, {"stt": new_label}, proc, t), f"{stt_label}->{new_label}")
            time.sleep(2)

        if "setting" in arms:
            new_mode = MODES[1 - mode]
            write(home, [("cleanup.mode", new_mode)])
            t = time.perf_counter()
            os.kill(proc.pid, signal.SIGHUP)
            row("setting", wait_idle(home, {"mode": new_mode}, proc, t), f"{MODES[mode]}->{new_mode}")
            time.sleep(2)

        t = time.perf_counter()
        os.kill(proc.pid, signal.SIGTERM)
        proc.wait(timeout=TIMEOUT_S)
        row("stop", time.perf_counter() - t, "sigterm")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        out.close()
    return rows


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--scratch", type=Path, required=True, help="folder with home/ and hf/ holding the models")
    p.add_argument("--rounds", type=int, default=6)
    p.add_argument("--checkout", action="append", required=True, help="name=path to a v2t checkout")
    p.add_argument("--max-load", type=float, default=25.0, help="wait while the 1-minute load is above this")
    p.add_argument("--arms", default=",".join(ARMS[2:]),
                   help="comma-separated: cleanup, speech, setting (start and stop always run)")
    p.add_argument("--cleanup", choices=CLEANUP, help="the cleanup model to start with (default the first)")
    a = p.parse_args()
    arms = set(a.arms.split(",")) | {"live", "start", "stop"}
    unknown = arms - set(ARMS)
    if unknown:
        p.error(f"unknown arms: {', '.join(sorted(unknown))}")
    cleanups = (a.cleanup, *(c for c in CLEANUP if c != a.cleanup)) if a.cleanup else CLEANUP
    a.scratch = a.scratch.resolve()  # the engines run with their temporary home as cwd
    checkouts = [(n, Path(s).resolve()) for n, s in (c.split("=", 1) for c in a.checkout)]
    rows = []
    with open(a.scratch / "results.jsonl", "a") as log:
        for rnd in range(a.rounds):
            order = checkouts if rnd % 2 == 0 else checkouts[::-1]
            for name, source in order:
                while os.getloadavg()[0] > a.max_load:
                    time.sleep(30)
                rows += run_checkout(name, source, a.scratch, rnd, log, arms, cleanups)
    print("\nmedian seconds (n)")
    for arm in (arm for arm in ARMS if arm in arms):
        cells = []
        for name, _ in checkouts:
            xs = [r["seconds"] for r in rows if r["arm"] == arm and r["checkout"] == name]
            cells.append(f"{name} {statistics.median(xs):.2f} ({len(xs)})" if xs else f"{name} -")
        print(f"{arm:8} " + "   ".join(cells))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
