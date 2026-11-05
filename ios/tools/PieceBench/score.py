# /// script
# requires-python = ">=3.11"
# dependencies = ["kaldialign>=0.12", "num2words", "regex", "matplotlib"]
# ///
"""Score piece-bench results (#112): whole-file against pieces, per set and model.

    uv run ios/tools/PieceBench/score.py [--dir ~/.v2t/eval/piece-bench] [--plot out.png]

Words wrong use the Open ASR Leaderboard's normaliser and alignment (utils/asr_grid/oasr). Labelled sets are
scored against their references; `wispr` (real dictations, no references) against utils/asr_grid's silver
text. For every set, `agree` is the pieces' text scored against the whole-file text of the same model, and
`fmt` the same with punctuation and capitals kept, so a full stop or capital added at a cut shows. The
difference in WER (pieces − whole) carries a 95% interval from resampling clips, paired.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "utils/asr_grid"))
from oasr import edits, normalise  # noqa: E402

SETS = ["wispr", "ls-long", "ls-clean", "ls-other", "fleurs-es"]
GRID = Path.home() / ".v2t/eval/grid"
ONE_WINDOW_S = 14.9  # below this a recording is one piece, decoded as before


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line] if path.exists() else []


def references(set_name: str) -> dict[str, str]:
    if set_name == "wispr":
        return {r["id"]: r["text"] for r in load(GRID / "silver/wispr.jsonl")}
    return {r["id"]: r["text"] for r in load(GRID / f"sets/{set_name}.jsonl") if r.get("text")}


def errors(ref: str, hyp: str, lang: str) -> tuple[int, int]:
    r = normalise(ref, lang)
    return edits(r, normalise(hyp, lang), lang), len(r)


def formatted(ref: str, hyp: str) -> tuple[int, int]:
    """Word errors on the raw words, punctuation and capitals kept (plain Levenshtein)."""
    a, b = ref.split(), hyp.split()
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1], len(a)


def paired_interval(pairs: list[tuple[int, int, int]], n: int = 2000) -> tuple[float, float]:
    """95% interval of pooled WER(pieces) − WER(whole) in points; pairs are (whole errs, pieces errs, words)."""
    rng = random.Random(112)
    diffs = []
    for _ in range(n):
        sample = [pairs[rng.randrange(len(pairs))] for _ in pairs]
        words = sum(p[2] for p in sample) or 1
        diffs.append(100 * (sum(p[1] for p in sample) - sum(p[0] for p in sample)) / words)
    diffs.sort()
    return diffs[int(0.025 * n)], diffs[int(0.975 * n) - 1]


def pct(e: int, w: int) -> float:
    return 100 * e / w if w else float("nan")


def score(rows: list[dict], refs: dict[str, str]) -> dict:
    pairs, agree, fmt = [], [0, 0], [0, 0]
    same_short = short = 0
    for r in rows:
        lang = r["lang"]
        if r["duration_s"] < ONE_WINDOW_S:
            short += 1
            same_short += r["whole"] == r["pieces"]
        e, w = errors(r["whole"], r["pieces"], lang)
        agree[0] += e
        agree[1] += w
        e, w = formatted(r["whole"], r["pieces"])
        fmt[0] += e
        fmt[1] += w
        if r["id"] in refs:
            ew, words = errors(refs[r["id"]], r["whole"], lang)
            ep, _ = errors(refs[r["id"]], r["pieces"], lang)
            pairs.append((ew, ep, words))
    out = {"clips": len(rows), "short": short, "short_identical": same_short,
           "agree": pct(*agree), "fmt": pct(*fmt), "scored": len(pairs)}
    if pairs:
        words = sum(p[2] for p in pairs)
        out["whole_wer"] = pct(sum(p[0] for p in pairs), words)
        out["pieces_wer"] = pct(sum(p[1] for p in pairs), words)
        out["diff_ci"] = paired_interval(pairs)
    return out


BUCKETS = [(0, 14.9), (14.9, 30), (30, 60), (60, 120), (120, 300), (300, 1e9)]


def timings(rows: list[dict]) -> list[dict]:
    out = []
    for lo, hi in BUCKETS:
        b = [r for r in rows if lo <= r["duration_s"] < hi]
        if not b:
            continue
        whole = statistics.median(r["whole_s"] for r in b)
        wait = statistics.median(r["wait_s"] for r in b)
        ratios = sorted(r["wait_s"] / r["whole_s"] for r in b if r["whole_s"] > 0)
        out.append({"bucket": f"{lo:g}-{hi:g} s" if hi < 1e9 else f"{lo:g} s+", "n": len(b), "whole_p50": whole,
                    "pieces_p50": wait, "ratio_p50": statistics.median(ratios),
                    "backlog_max": max(r["backlog_s"] for r in b),
                    "fell_back": sum(r["fell_back"] for r in b)})
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--dir", type=Path, default=Path.home() / ".v2t/eval/piece-bench")
    p.add_argument("--plot", type=Path)
    a = p.parse_args()
    print("| model | set | clips | whole WER | pieces WER | Δ points (95% CI) | pieces vs whole | with punctuation | under 14.9 s identical |")
    print("|---|---|--:|--:|--:|--:|--:|--:|--:|")
    for arm in ("nemotron", "parakeet"):
        for s in SETS:
            rows = load(a.dir / f"{s}.{arm}.jsonl")
            if not rows:
                continue
            m = score(rows, references(s))
            wer = (f"{m['whole_wer']:.2f} | {m['pieces_wer']:.2f} | {m['pieces_wer'] - m['whole_wer']:+.2f} "
                   f"({m['diff_ci'][0]:+.2f} to {m['diff_ci'][1]:+.2f})") if "whole_wer" in m else "– | – | –"
            print(f"| {arm} | {s}{' (silver)' if s == 'wispr' else ''} | {m['clips']} | {wer} | {m['agree']:.2f} | "
                  f"{m['fmt']:.2f} | {m['short_identical']}/{m['short']} |")
    print()
    print("| model | dictation length | clips | whole-file, Stop to text p50 | pieces, Stop to text p50 | ratio p50 | longest backlog | fell back |")
    print("|---|---|--:|--:|--:|--:|--:|--:|")
    every: dict[str, list[dict]] = {}
    for arm in ("nemotron", "parakeet"):
        rows = [r for s in SETS for r in load(a.dir / f"{s}.{arm}.jsonl")]
        every[arm] = rows
        for t in timings(rows):
            print(f"| {arm} | {t['bucket']} | {t['n']} | {t['whole_p50']:.3f} s | {t['pieces_p50']:.3f} s | "
                  f"{t['ratio_p50']:.2f} | {t['backlog_max']:.3f} s | {t['fell_back']} |")
    if a.plot:
        plot(every, a.plot)


def plot(every: dict[str, list[dict]], path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(1, 2, figsize=(11, 4.2), dpi=200, sharey=True)
    names = {"nemotron": "Nemotron Unified int8", "parakeet": "Parakeet v3 int8"}
    for ax, (arm, rows) in zip(axes, every.items()):
        rows = [r for r in rows if r["duration_s"] >= 1]
        ax.scatter([r["duration_s"] for r in rows], [r["whole_s"] for r in rows], s=6, c="#9aa0a6", label="whole file after Stop")
        ax.scatter([r["duration_s"] for r in rows], [r["wait_s"] for r in rows], s=6, c="#d93025", label="pieces while recording")
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_title(names.get(arm, arm), fontsize=10)
        ax.set_xlabel("dictation length (s)")
        ax.grid(alpha=0.3, which="both", lw=0.4)
    axes[0].set_ylabel("Stop to text on this Mac (s)")
    axes[0].legend(fontsize=8, loc="upper left")
    fig.tight_layout()
    fig.savefig(path)


if __name__ == "__main__":
    main()
