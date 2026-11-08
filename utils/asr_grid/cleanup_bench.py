"""Benchmark v2t's cleanup on its own: does it add or lose words, and does it format well?

Maintainer-only. Runs v2t's cleanup (engine, model, mode and the user's dictionary, as
the app would) over the transcripts grid systems already produced on labelled sets,
then scores the raw and the cleaned text against the references.

    .venv/bin/python utils/asr_grid/cleanup_bench.py run      # resumable; the configured cleanup
    .venv/bin/python utils/asr_grid/cleanup_bench.py report

    # one model of the Cleanup Model picker, in its own folder (#129)
    .venv/bin/python utils/asr_grid/cleanup_bench.py run --cleanup mlx:mlx-community/Qwen3.5-0.8B-4bit \
        --systems parakeet-v3 --sets ls-clean
    .venv/bin/python utils/asr_grid/cleanup_bench.py models   # one table, every model run so far

Two scores per (set, system): WER after Whisper normalisation, raw against cleaned (the
words), and on Earnings22, whose references keep punctuation and capitals, a formatted
WER that counts those too (the cleanup's other job). The configured cleanup writes under
~/.v2t/eval/grid/cleanup/<set>/<system>.jsonl; `--cleanup` writes under
~/.v2t/eval/grid/cleanup-models/<model>/, and each row there also keeps the model's own
text before v2t's guards (`model`), the load average, and the run's memory (`run.jsonl`).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import grid

SETS = ("ls-clean", "ls-other", "ami-sdm", "earnings22")
SYSTEMS = ("parakeet-v3", "parakeet-unified-en", "qwen3-asr-1.7b-8bit")
OUT = grid.GRID / "cleanup"
MODELS = grid.GRID / "cleanup-models"
# The maintainer's 208 dictations, scored against Wispr Flow's formatted text: a reference to compare with,
# not ground truth, and never a tuning target (its terms allow the one, not the other, #122)
WISPR = "wispr"
WISPR_MODELS = grid.GRID / "cleanup-wispr"
WISPR_REFS = grid.EVAL / "wisprflow" / "results-2b-casual.jsonl"
FORMATTED = ("earnings22",)  # references with punctuation and capitals
ANSWER = 1.3  # an output this many times the input's words is an answer or a continuation
_TOKEN = re.compile(r"\w+(?:['’]\w+)*|[^\w\s]")


def _footprint_mb(pid: int) -> float | None:
    """The process's physical footprint, what Activity Monitor calls Memory: unlike RSS
    it counts the GPU buffers MLX holds in unified memory."""
    out = subprocess.run(["/usr/bin/footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", out)
    if not m:
        return None
    return round(float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)], 1)


def _rss_mb(pid: int) -> float | None:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return round(int(out) / 1024, 1) if out else None


def _ollama_runner_mb() -> float | None:
    """Ollama keeps the model in its runner process, not in v2t's worker (`ollama runner`, or
    since about 0.40 a llama-server under Ollama's lib folder)."""
    pids = subprocess.run(["pgrep", "-f", "ollama runner|lib/ollama/llama-server"],
                          capture_output=True, text=True).stdout.split()
    # llama.cpp maps its weights, so they show in RSS but not all in the footprint: take the larger
    sizes = [max(_footprint_mb(int(p)) or 0, _rss_mb(int(p)) or 0) for p in pids]
    return round(sum(sizes), 1) if any(sizes) else None


def _machine() -> dict:
    free = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout.strip().splitlines()
    disk = subprocess.run(["df", "-g", "/"], capture_output=True, text=True).stdout.split("\n")[1].split()
    return {"t": round(time.time()), "load": [round(x, 1) for x in os.getloadavg()],
            "mem_free": free[-1].rsplit(" ", 1)[-1] if free else None, "disk_free_gb": int(disk[3])}


def _memory(engine: str) -> dict:
    pid = os.getpid()
    out = {"footprint_mb": _footprint_mb(pid), "rss_mb": _rss_mb(pid)}
    if engine == "ollama":
        out["ollama_runner_mb"] = _ollama_runner_mb()
    return out


def _record_model_text(cleaner) -> list[str]:
    """Collect what the model writes per chunk, before v2t's length guard and
    keep_spoken_words, so the model can be scored on its own as well."""
    seen: list[str] = []
    generate = cleaner._generate

    def wrapped(chunk, mode):
        text, ttft, limited = generate(chunk, mode)
        seen.append(text.strip())
        return text, ttft, limited

    cleaner._generate = wrapped
    return seen


def run(args) -> None:
    sys.path.insert(0, str(grid.REPO))
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    from v2t import backends, config

    cfg = config.load()
    vocabulary, replacements = config.read_dictionary()
    engine, model, mode = cfg.cleanup_engine, cfg.cleanup_model, args.mode or cfg.mode
    if args.cleanup:
        engine, _, model = args.cleanup.partition(":")
    before = {**_machine(), **_memory(engine)}
    t0 = time.perf_counter()
    cleaner = backends.make_cleanup(engine, model, cfg.ollama_url)
    cleaner.vocabulary = tuple(vocabulary)
    root = WISPR_MODELS if args.sets == [WISPR] else MODELS
    out = root / (backends.short_model(cleaner.model_id) + (f"@{args.tag}" if args.tag else "")) if args.cleanup else OUT
    if WISPR in args.sets and (not args.cleanup or args.sets != [WISPR]):
        raise SystemExit("--sets wispr goes on its own, with --cleanup")
    print(f"cleanup: {cleaner.model_id}, {mode}, {len(vocabulary)} terms, {len(replacements)} replacements -> {out}")
    _check_signature(out, _signature(cleaner.model_id, mode, vocabulary, replacements))
    model_text = _record_model_text(cleaner) if args.cleanup else []
    # the first call builds the prompt's prefix cache (MLX) or loads the model (Ollama)
    cleaner.cleanup("so um I think we should meet on Tuesday", mode)
    loaded = {**_memory(engine), "load_s": round(time.perf_counter() - t0, 2)}
    done_rows = 0
    for set_name in args.sets:
        clips = {c["id"]: c for c in grid.read_jsonl(grid.SETS / f"{set_name}.jsonl")}
        for system in args.systems:
            rows = grid.read_jsonl(grid.RESULTS / set_name / f"{system}.jsonl")
            path = grid.private_dir(out / set_name) / f"{system}.jsonl"
            done = {r["id"] for r in grid.read_jsonl(path)}
            todo = [r for r in rows if r["id"] in clips and r["id"] not in done]
            if not todo:
                continue
            print(f"{set_name} / {system}: {len(todo)} to clean", flush=True)
            with path.open("a") as f:
                os.chmod(path, 0o600)
                for r in todo:
                    raw = grid.final_text(system, r)
                    model_text.clear()
                    t1 = time.perf_counter()
                    clean = (cleaner.cleanup(raw, mode)[0] or raw) if raw.strip() else raw
                    seconds = time.perf_counter() - t1
                    clean = config.apply_replacements(clean, replacements)
                    row = {"id": r["id"], "raw": raw, "clean": clean, "seconds": round(seconds, 3),
                           "stats": getattr(cleaner, "last_stats", {})}
                    if args.cleanup:
                        row["model"] = " ".join(model_text) if raw.strip() else raw
                        row["load1"] = round(os.getloadavg()[0], 1)
                    f.write(json.dumps(row) + "\n")
                    done_rows += 1
    if args.cleanup:
        with (grid.private_dir(out) / "run.jsonl").open("a") as f:
            f.write(json.dumps({"engine": engine, "model": cleaner.model_id, "sets": args.sets,
                                "systems": args.systems, "rows": done_rows, "before": before,
                                "loaded": loaded, "after": {**_machine(), **_memory(engine)}}) + "\n")


CODE = ("v2t", "pyproject.toml", "uv.lock")


def _signature(model: str, mode: str, vocabulary, replacements) -> dict:
    """What decides the cleaned text: model, mode, dictionary and v2t's own code (a
    dirty v2t/ adds a digest of its diff, so further edits change the signature)."""
    import hashlib

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(grid.REPO), *args], capture_output=True, text=True).stdout.strip()

    # in order: the vocabulary goes into the prompt as listed, replacements apply in turn
    dictionary = json.dumps([list(vocabulary), [list(r) for r in replacements]])
    return {
        "model": model, "mode": mode,
        "dictionary": hashlib.sha256(dictionary.encode()).hexdigest()[:16],
        # the last commit that changed v2t's code or its dependencies, so tool-only
        # commits keep a run resumable
        "v2t": git("log", "-1", "--format=%H", "--", *CODE)
        + (f"-dirty-{hashlib.sha256(diff.encode()).hexdigest()[:12]}" if (diff := git("diff", "HEAD", "--", *CODE)) else ""),
    }


def _check_signature(out: Path, signature: dict) -> None:
    """Resume only results made by the same cleanup; anything else would mix runs."""
    path = grid.private_dir(out) / "config.json"
    if path.exists():
        saved = json.loads(path.read_text())
        if saved != signature:
            changed = ", ".join(k for k in signature if saved.get(k) != signature[k])
            raise SystemExit(f"{out} holds results from another cleanup ({changed} changed): move it aside first")
    elif any(out.glob("*/*.jsonl")):
        raise SystemExit(f"{out} holds results with no record of the cleanup that made them: move it aside first")
    path.write_text(json.dumps(signature, indent=1) + "\n")


def _wer(pairs, tokenise) -> float:
    errors = words = 0
    for ref, hyp in pairs:
        r, h = tokenise(ref), tokenise(hyp)
        errors += grid.edits(r, h)
        words += len(r)
    return errors / max(words, 1)


def _norm(t: str) -> list[str]:
    return grid.normalise(t, "en")


def report() -> None:
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
            line = f"{set_name:11} {system:22} {100 * _wer(raw, _norm):7.2f}% {100 * _wer(clean, _norm):7.2f}%"
            if set_name in FORMATTED:
                line += f"  {100 * _wer(raw, fmt):13.2f}% {100 * _wer(clean, fmt):7.2f}%"
            print(line + f"   ({len(rows)} clips)")


def answers(rows) -> int:
    """Outputs more than ANSWER times the input's words: the model answered or went on."""
    return sum(len(r["model"].split()) > ANSWER * max(len(r["raw"].split()), 1) for r in rows if r["raw"].strip())


def _memory_cell(runs: list[dict]) -> str:
    """Largest footprint once loaded and warm, then after cleaning (MLX keeps a buffer cache);
    for Ollama the runner process, which holds the model instead of v2t's worker."""
    if not runs:
        return "–"
    key = "ollama_runner_mb" if runs[0]["engine"] == "ollama" else "footprint_mb"
    loaded = max(r["loaded"].get(key) or 0 for r in runs) / 1024
    after = max(r["after"].get(key) or 0 for r in runs) / 1024
    return f"{loaded:.1f} / {after:.1f} GB" + (" (Ollama runner)" if key == "ollama_runner_mb" else "")


def models(args) -> None:
    """One markdown table over every model run with --cleanup, on the clips they all share."""
    system = args.systems[0]
    names = sorted(p.name for p in MODELS.iterdir() if any(p.glob(f"*/{system}.jsonl"))) if MODELS.exists() else []
    if not names:
        raise SystemExit(f"no {system} results under {MODELS}: run with --cleanup first")
    data = {n: {s: {r["id"]: r for r in grid.read_jsonl(MODELS / n / s / f"{system}.jsonl")} for s in SETS} for n in names}
    shared = {s: set.intersection(*(set(data[n][s]) for n in names)) for s in SETS}
    refs = {s: {c["id"]: c["text"] for c in grid.read_jsonl(grid.SETS / f"{s}.jsonl")} for s in SETS}
    sets = [s for s in SETS if shared[s]]
    if not sets:
        raise SystemExit(f"the models under {MODELS} share no clips on any set: run them on the same --sets")
    head = ["model"] + [f"{s} WER (model / guarded)" for s in sets]
    if "earnings22" in sets:
        head.append("e22 formatted, guarded")
    head += [f">{ANSWER}x", "guard reverts", "p50 / p90 s per clip", "memory loaded / after run"]
    first = data[names[0]]
    raw_line = ["raw transcript"] + [f"{100 * _wer([(refs[s][i], first[s][i]['raw']) for i in sorted(shared[s])], _norm):.2f}" for s in sets]
    if "earnings22" in sets:
        e = sorted(shared["earnings22"])
        raw_line.append(f"{100 * _wer([(refs['earnings22'][i], first['earnings22'][i]['raw']) for i in e], _TOKEN.findall):.2f}")
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" + "--:|" * (len(head) - 1))
    print("| " + " | ".join(raw_line + ["–"] * 4) + " |")
    for n in names:
        rows = [data[n][s][i] for s in sets for i in sorted(shared[s])]
        cells = [n]
        for s in sets:
            ids = sorted(shared[s])
            m = _wer([(refs[s][i], data[n][s][i]["model"]) for i in ids], _norm)
            g = _wer([(refs[s][i], data[n][s][i]["clean"]) for i in ids], _norm)
            cells.append(f"{100 * m:.2f} / {100 * g:.2f}")
        if "earnings22" in sets:
            e = sorted(shared["earnings22"])
            cells.append(f"{100 * _wer([(refs['earnings22'][i], data[n]['earnings22'][i]['clean']) for i in e], _TOKEN.findall):.2f}")
        secs = sorted(r["seconds"] for r in rows)
        reverts = sum(r["stats"].get("guarded", 0) + r["stats"].get("limited", 0) for r in rows)
        chunks = sum(r["stats"].get("chunks", 0) for r in rows)
        runs = grid.read_jsonl(MODELS / n / "run.jsonl")
        cells += [str(answers(rows)), f"{reverts} of {chunks}",
                  f"{statistics.median(secs):.2f} / {secs[math.ceil(0.9 * len(secs)) - 1]:.2f}", _memory_cell(runs)]
        print("| " + " | ".join(cells) + " |")
    print(f"\n{system}, clips per set: " + ", ".join(f"{s} {len(shared[s])}" for s in sets))


def wispr(args) -> None:
    """One table: each model run with --sets wispr against Wispr Flow's formatted text, on the dictations
    where Wispr kept its formatting (not cut short) and every model has a row."""
    system = args.systems[0]
    refs = {r["id"]: r["wispr_formatted"] for r in grid.read_jsonl(WISPR_REFS)
            if r.get("wispr_formatted") and not r.get("wispr_cut")}
    names = sorted(p.parent.parent.name for p in WISPR_MODELS.glob(f"*/{WISPR}/{system}.jsonl"))
    if not names:
        raise SystemExit(f"no {system} results under {WISPR_MODELS}: run with --cleanup ... --sets wispr first")
    data = {n: {r["id"]: r for r in grid.read_jsonl(WISPR_MODELS / n / WISPR / f"{system}.jsonl")} for n in names}
    ids = sorted(set(refs).intersection(*(set(d) for d in data.values())))
    if not ids:
        raise SystemExit("no dictation has both a Wispr formatted text and a row from every model")
    fmt = _TOKEN.findall
    print("| model | WER vs Wispr (model / guarded) | formatted WER vs Wispr, guarded | >1.3x | guard reverts | p50 / p90 s per dictation |")
    print("|---|--:|--:|--:|--:|--:|")
    first = data[names[0]]
    print(f"| raw transcript | {100 * _wer([(refs[i], first[i]['raw']) for i in ids], _norm):.2f} | "
          f"{100 * _wer([(refs[i], first[i]['raw']) for i in ids], fmt):.2f} | – | – | – |")
    for n in names:
        rows = [data[n][i] for i in ids]
        secs = sorted(r["seconds"] for r in rows)
        reverts = sum(r["stats"].get("guarded", 0) + r["stats"].get("limited", 0) for r in rows)
        print(f"| {n} | {100 * _wer([(refs[i], data[n][i]['model']) for i in ids], _norm):.2f} / "
              f"{100 * _wer([(refs[i], data[n][i]['clean']) for i in ids], _norm):.2f} | "
              f"{100 * _wer([(refs[i], data[n][i]['clean']) for i in ids], fmt):.2f} | {answers(rows)} | "
              f"{reverts} of {sum(r['stats'].get('chunks', 0) for r in rows)} | "
              f"{statistics.median(secs):.2f} / {secs[math.ceil(0.9 * len(secs)) - 1]:.2f} |")
    print(f"\n{system}, {len(ids)} dictations (Wispr formatted, not cut short)")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("command", nargs="?", default="report", choices=("run", "report", "models", "wispr"))
    p.add_argument("--cleanup", help="engine:model, e.g. mlx:mlx-community/Qwen3.5-0.8B-4bit or ollama:qwen3:4b-instruct-2507-q4_K_M")
    p.add_argument("--mode", help="cleanup mode (default: the configured one)")
    p.add_argument("--tag", help="with --cleanup: a suffix for the model's folder (<model>@<tag>), to keep a run of "
                   "changed v2t code beside the earlier one")
    p.add_argument("--sets", nargs="+", default=list(SETS), choices=(*SETS, WISPR),
                   help="labelled sets (default all four), or wispr on its own: the maintainer's dictations")
    p.add_argument("--systems", nargs="+", default=list(SYSTEMS), choices=SYSTEMS)
    args = p.parse_args()
    if args.command in ("models", "wispr") and args.systems == list(SYSTEMS):
        args.systems = ["parakeet-v3"]
    {"run": run, "report": lambda a: report(), "models": models, "wispr": wispr}[args.command](args)


if __name__ == "__main__":
    main()
