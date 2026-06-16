"""Benchmark STT (MLX) and cleanup (Ollama) models -> a markdown grid.

Each table is models-as-columns. STT needs Apple Silicon; cleanup needs Ollama.
Results are written to benchmarks/results/<date>-<host>.md so you can build a grid
across machines: run on each Mac, commit the file. Absolute times reflect THAT
machine — compare models within a run, not across machines.

    v2t bench                      # both tables, default models, samples via `say`
    v2t bench --cleanup            # cleanup table only (runs anywhere Ollama runs)
    v2t bench --stt-models parakeet:mlx-community/parakeet-tdt-0.6b-v3 ...
"""

from __future__ import annotations

import argparse
import platform
import statistics
import subprocess
import time
import wave
from datetime import date
from pathlib import Path

from . import backends, config

STT_MODELS = [
    "parakeet:mlx-community/parakeet-tdt-0.6b-v3",
    "parakeet:mlx-community/parakeet-tdt-0.6b-v2",
    "whisper:mlx-community/whisper-large-v3-turbo",
]
CLEANUP_MODELS = ["qwen3:4b-instruct-2507", "qwen3:1.7b", "qwen2.5:3b"]

# (name, text) — `say` turns these into audio so the STT bench is self-contained.
SAY_SAMPLES = [
    ("short", "Hey, can you send me the report by end of day? Thanks a lot."),
    ("medium", "So basically I was thinking we could try the other approach for the migration, "
               "move the read traffic over first, watch the error rates for a day, and then cut the "
               "writes once we're confident nothing is on fire."),
    ("long", "Right, so the plan for next quarter. First, we finish the local transcription work, "
             "because the cloud dependency keeps breaking behind the corporate VPN and it's just not "
             "worth fighting. Second, we ship the menu bar toggle so it's one click to start and stop. "
             "Third, we benchmark every model on each machine, write the numbers down, and stop guessing "
             "which one is fastest. None of this is hard, it just needs doing, and I'd rather spend the "
             "time once than keep re-litigating it every single week in standup."),
]

# Filler-laden raw transcriptions for the cleanup table.
CLEANUP_SAMPLES = [
    "Hey um I'll see you tomorrow at 9 actually no make it 10",
    "So basically I was thinking we could um you know maybe try the other approach",
    "yeah so the the thing is like we need to ship this by friday otherwise uh it slips again",
]


def host_label() -> str:
    if platform.system() == "Darwin":
        def sysctl(key):
            return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True).stdout.strip()
        chip = sysctl("machdep.cpu.brand_string") or sysctl("hw.model") or "mac"
        return chip.replace(" ", "-")
    return platform.machine() + "-" + platform.system().lower()


def wav_duration(path: Path) -> float:
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def ensure_samples(directory: Path) -> list[tuple[str, Path, float]]:
    """Synthesize the SAY_SAMPLES with macOS `say` -> 16k mono wav (via afconvert)."""
    directory.mkdir(parents=True, exist_ok=True)
    out = []
    for name, text in SAY_SAMPLES:
        wav = directory / f"{name}.wav"
        if not wav.exists():
            aiff = directory / f"{name}.aiff"
            subprocess.run(["say", "-o", str(aiff), text], check=True)
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
                check=True,
            )
            aiff.unlink(missing_ok=True)
        out.append((name, wav, wav_duration(wav)))
    return out


def _median(xs: list[float]) -> float:
    return statistics.median(xs)


def bench_stt(model_specs: list[str], samples, repeat: int) -> dict:
    """{spec: {"load": s, sample_name: (proc_s, rtf)}} — model loaded once, reused."""
    results = {}
    for spec in model_specs:
        backend, _, model = spec.partition(":")
        print(f"  STT {spec} ... loading")
        t0 = time.perf_counter()
        stt = backends.make_stt(backend, model)
        results[spec] = {"load": time.perf_counter() - t0}
        for name, wav, dur in samples:
            times = []
            for _ in range(repeat):
                t = time.perf_counter()
                stt.transcribe(str(wav))
                times.append(time.perf_counter() - t)
            proc = _median(times)
            results[spec][name] = (proc, dur / proc if proc else 0.0)
            print(f"    {name} ({dur:.1f}s): {proc:.2f}s  RTF {dur/proc:.0f}x")
    return results


def bench_cleanup(models: list[str], samples: list[str], repeat: int, url: str) -> dict:
    """{model: {sample_idx: (ttft_s, total_s)}}."""
    results = {}
    for model in models:
        print(f"  cleanup {model} ... warming up")
        backends.cleanup("hi", model, url=url)  # pull/warm
        results[model] = {}
        for i, sample in enumerate(samples):
            ttfts, totals = [], []
            for _ in range(repeat):
                _text, ttft, total = backends.cleanup(sample, model, url=url)
                ttfts.append(ttft if ttft is not None else total)
                totals.append(total)
            results[model][i] = (_median(ttfts), _median(totals))
            print(f"    sample {i}: ttft {results[model][i][0]:.2f}s  total {results[model][i][1]:.2f}s")
    return results


def md_stt_table(results: dict, samples) -> str:
    specs = list(results)
    head = "| sample | " + " | ".join(backends.STT[s.split(':')[0]].__name__.replace("STT", "") +
                                       " " + (s.split(':')[1].rsplit('/', 1)[-1]) for s in specs) + " |"
    sep = "|---|" + "|".join("--:" for _ in specs) + "|"
    rows = [f"| load | " + " | ".join(f"{results[s]['load']:.1f}s" for s in specs) + " |"]
    for name, _wav, dur in samples:
        cells = " | ".join(f"{results[s][name][0]:.2f}s ({results[s][name][1]:.0f}x)" for s in specs)
        rows.append(f"| {name} ({dur:.1f}s) | {cells} |")
    note = "\n_Cells: transcription time (real-time factor). Higher RTF = faster._"
    return "\n".join(["**Speech-to-text** — time & RTF", "", head, sep, *rows]) + "\n" + note


def md_cleanup_table(results: dict, samples: list[str]) -> str:
    models = list(results)
    head = "| sample | " + " | ".join(models) + " |"
    sep = "|---|" + "|".join("--:" for _ in models) + "|"
    rows = []
    for i in range(len(samples)):
        cells = " | ".join(f"{results[m][i][0]:.2f} / {results[m][i][1]:.2f}s" for m in models)
        rows.append(f"| {i} | {cells} |")
    med = " | ".join(
        f"{_median([results[m][i][0] for i in range(len(samples))]):.2f} / "
        f"{_median([results[m][i][1] for i in range(len(samples))]):.2f}s" for m in models
    )
    rows.append(f"| **median** | {med} |")
    note = "\n_Cells: time-to-first-token / total. Lower is better._"
    return "\n".join(["**Text cleanup** — TTFT & total", "", head, sep, *rows]) + "\n" + note


def write_results(body: str, out: Path | None) -> Path:
    out = out or (Path("benchmarks/results") / f"{date.today()}-{host_label()}.md")
    out.parent.mkdir(parents=True, exist_ok=True)
    header = f"# v2t benchmark — {host_label()} — {date.today()}\n\n_Compare models within this file; absolute times are machine-specific._\n\n"
    out.write_text(header + body + "\n")
    return out


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="v2t bench")
    p.add_argument("--stt", action="store_true", help="run the STT table only")
    p.add_argument("--cleanup", action="store_true", help="run the cleanup table only")
    p.add_argument("--stt-models", nargs="+", default=STT_MODELS, help="backend:model specs")
    p.add_argument("--cleanup-models", nargs="+", default=CLEANUP_MODELS, help="ollama model names")
    p.add_argument("--repeat", type=int, default=3, help="runs per cell, median reported")
    p.add_argument("--audio", type=Path, default=config.home() / "bench-audio", help="sample wav dir")
    p.add_argument("--url", default="http://localhost:11434", help="ollama base url")
    p.add_argument("--out", type=Path, help="results markdown path")
    a = p.parse_args(argv)

    do_stt = a.stt or not a.cleanup
    do_cleanup = a.cleanup or not a.stt
    sections = []

    if do_stt:
        print("Speech-to-text:")
        samples = ensure_samples(a.audio)
        sections.append(md_stt_table(bench_stt(a.stt_models, samples, a.repeat), samples))
    if do_cleanup:
        print("Text cleanup:")
        sections.append(md_cleanup_table(bench_cleanup(a.cleanup_models, CLEANUP_SAMPLES, a.repeat, a.url), CLEANUP_SAMPLES))

    out = write_results("\n\n".join(sections), a.out)
    print(f"\nwrote {out}")
    print("\n" + "\n\n".join(sections))
    return 0


if __name__ == "__main__":
    # ponytail: check the pure table builders with fake data (no models needed).
    fake = {
        "parakeet:x/parakeet-tdt-0.6b-v3": {"load": 1.2, "short": (0.10, 60.0)},
        "whisper:x/whisper-large-v3-turbo": {"load": 3.4, "short": (0.50, 12.0)},
    }
    t = md_stt_table(fake, [("short", Path("x"), 6.0)])
    assert "0.10s (60x)" in t and "load" in t, t
    fakec = {"qwen3:4b-instruct-2507": {0: (0.2, 0.9)}, "qwen2.5:3b": {0: (0.3, 1.1)}}
    c = md_cleanup_table(fakec, ["x"])
    assert "0.20 / 0.90s" in c and "median" in c, c
    print("bench.py: table-builder checks passed")
