"""Benchmark v2t's cleanup on its own: does it add or lose words, and does it format well?

Maintainer-only. Runs v2t's configured cleanup (engine, model, mode and the user's
dictionary, as the app would) over the transcripts grid systems already produced on
labelled sets, then scores the raw and the cleaned text against the references.

    .venv/bin/python utils/asr_grid/cleanup_bench.py run      # resumable; one model on the GPU
    .venv/bin/python utils/asr_grid/cleanup_bench.py report

Two scores per (set, system): WER after Whisper normalisation, raw against cleaned (the
words), and on Earnings22, whose references keep punctuation and capitals, a formatted
WER that counts those too (the cleanup's other job). Results go under
~/.v2t/eval/grid/cleanup/<set>/<system>.jsonl.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import grid

SETS = ("ls-clean", "ls-other", "ami-sdm", "earnings22")
SYSTEMS = ("parakeet-v3", "parakeet-unified-en", "qwen3-asr-1.7b-8bit")
OUT = grid.GRID / "cleanup"
FORMATTED = ("earnings22",)  # references with punctuation and capitals
_TOKEN = re.compile(r"\w+(?:['’]\w+)*|[^\w\s]")


def run() -> None:
    sys.path.insert(0, str(grid.REPO))
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    from v2t import backends, config

    cfg = config.load()
    vocabulary, replacements = config.read_dictionary()
    cleaner = backends.make_cleanup(cfg.cleanup_engine, cfg.cleanup_model, cfg.ollama_url)
    cleaner.vocabulary = tuple(vocabulary)
    print(f"cleanup: {cleaner.model_id}, {cfg.mode}, {len(vocabulary)} terms, {len(replacements)} replacements")
    _check_signature(_signature(cleaner.model_id, cfg.mode, vocabulary, replacements))
    for set_name in SETS:
        clips = {c["id"]: c for c in grid.read_jsonl(grid.SETS / f"{set_name}.jsonl")}
        for system in SYSTEMS:
            rows = grid.read_jsonl(grid.RESULTS / set_name / f"{system}.jsonl")
            path = grid.private_dir(OUT / set_name) / f"{system}.jsonl"
            done = {r["id"] for r in grid.read_jsonl(path)}
            todo = [r for r in rows if r["id"] in clips and r["id"] not in done]
            if not todo:
                continue
            print(f"{set_name} / {system}: {len(todo)} to clean", flush=True)
            with path.open("a") as f:
                os.chmod(path, 0o600)
                for r in todo:
                    raw = grid.final_text(system, r)
                    t0 = time.perf_counter()
                    clean = (cleaner.cleanup(raw, cfg.mode)[0] or raw) if raw.strip() else raw
                    clean = config.apply_replacements(clean, replacements)
                    f.write(json.dumps({"id": r["id"], "raw": raw, "clean": clean,
                                        "seconds": round(time.perf_counter() - t0, 3),
                                        "stats": getattr(cleaner, "last_stats", {})}) + "\n")


def _signature(model: str, mode: str, vocabulary, replacements) -> dict:
    """What decides the cleaned text: model, mode, dictionary and v2t's own code."""
    import hashlib
    import subprocess

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(grid.REPO), *args], capture_output=True, text=True).stdout.strip()

    dictionary = json.dumps([sorted(vocabulary), sorted(map(list, replacements))], sort_keys=True)
    return {
        "model": model, "mode": mode,
        "dictionary": hashlib.sha256(dictionary.encode()).hexdigest()[:16],
        "v2t": git("rev-parse", "HEAD") + ("-dirty" if git("status", "--porcelain", "--", "v2t") else ""),
    }


def _check_signature(signature: dict) -> None:
    """Resume only results made by the same cleanup; anything else would mix runs."""
    path = grid.private_dir(OUT) / "config.json"
    if path.exists():
        saved = json.loads(path.read_text())
        if saved != signature:
            changed = ", ".join(k for k in signature if saved.get(k) != signature[k])
            raise SystemExit(f"{OUT} holds results from another cleanup ({changed} changed): move it aside first")
    elif any(OUT.glob("*/*.jsonl")):
        raise SystemExit(f"{OUT} holds results with no record of the cleanup that made them: move it aside first")
    path.write_text(json.dumps(signature, indent=1) + "\n")


def _wer(pairs, tokenise) -> float:
    errors = words = 0
    for ref, hyp in pairs:
        r, h = tokenise(ref), tokenise(hyp)
        errors += grid.edits(r, h)
        words += len(r)
    return errors / max(words, 1)


def report() -> None:
    def norm(t: str) -> list[str]:
        return grid.normalise(t, "en")

    fmt = _TOKEN.findall
    print(f"{'set':11} {'system':22} {'WER raw':>8} {'cleaned':>8}" + f"  {'formatted raw':>14} {'cleaned':>8}")
    for set_name in SETS:
        clips = {c["id"]: c for c in grid.read_jsonl(grid.SETS / f"{set_name}.jsonl")}
        for system in SYSTEMS:
            rows = grid.read_jsonl(OUT / set_name / f"{system}.jsonl")
            if not rows:
                continue
            raw = [(clips[r["id"]]["text"], r["raw"]) for r in rows]
            clean = [(clips[r["id"]]["text"], r["clean"]) for r in rows]
            line = f"{set_name:11} {system:22} {100 * _wer(raw, norm):7.2f}% {100 * _wer(clean, norm):7.2f}%"
            if set_name in FORMATTED:
                line += f"  {100 * _wer(raw, fmt):13.2f}% {100 * _wer(clean, fmt):7.2f}%"
            print(line + f"   ({len(rows)} clips)")


if __name__ == "__main__":
    {"run": run, "report": report}[sys.argv[1] if len(sys.argv) > 1 else "report"]()
