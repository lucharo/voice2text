"""Compare tagged runs of bench_wisprflow.py (model x mode cells) in one table.

    uv run python utils/wisprflow_benchmarking_profiling/compare_cells.py 15b-casual 15b-strict 4b-casual 4b-strict

Reads ~/.v2t/eval/wisprflow/results-<tag>.jsonl for each tag and prints, per cell:
cleanup latency (p50/p90), ms per raw word, share of raw words kept (median, p10),
how many chunks were pasted raw (length guard / token limit), and disagreement with
Wispr's formatted text on the clips Wispr did not cut. Numbers only.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path

OUT_DIR = Path.home() / ".v2t/eval/wisprflow"
_WORD = re.compile(r"[\w']+")


def words(text: str | None) -> int:
    return len(_WORD.findall(text or ""))


def q(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))]


def summarise(tag: str) -> dict:
    path = OUT_DIR / f"results-{tag}.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    cleaned = [r for r in rows if r.get("v2t_cleanup_ms") and words(r["v2t_raw"]) > 20]
    kept = [words(r["v2t_clean"]) / words(r["v2t_raw"]) for r in cleaned]
    per_word = [r["v2t_cleanup_ms"] / words(r["v2t_raw"]) for r in cleaned]
    latency = [r["v2t_cleanup_ms"] for r in cleaned]
    intact = [
        r for r in cleaned if not r.get("wispr_cut") and "dis_clean_vs_wispr_fmt" in r
    ]
    dis = [r["dis_clean_vs_wispr_fmt"] for r in intact]
    return {
        "tag": tag,
        "clips": len(cleaned),
        "p50_ms": q(latency, 0.5),
        "p90_ms": q(latency, 0.9),
        "ms_per_word": statistics.median(per_word),
        "kept_median": statistics.median(kept),
        "kept_p10": q(kept, 0.1),
        "under_0_75": sum(k < 0.75 for k in kept),
        "over_1_3": sum(k > 1.3 for k in kept),
        "dis_median": statistics.median(dis) if dis else float("nan"),
        "dis_p90": q(dis, 0.9) if dis else float("nan"),
    }


def main(tags: list[str]) -> int:
    if not tags:
        print(__doc__)
        return 2
    cells = [summarise(t) for t in tags]
    head = (
        "| cell | clips | cleanup p50 | p90 | ms/word | words kept p50 | p10 | "
        "<75% | >130% | vs Wispr fmt p50 | p90 |"
    )
    print(head)
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for c in cells:
        print(
            f"| {c['tag']} | {c['clips']} | {c['p50_ms'] / 1000:.2f}s | {c['p90_ms'] / 1000:.2f}s "
            f"| {c['ms_per_word']:.1f} | {c['kept_median']:.2f} | {c['kept_p10']:.2f} "
            f"| {c['under_0_75']} | {c['over_1_3']} | {c['dis_median']:.3f} | {c['dis_p90']:.3f} |"
        )
    print(
        "\n_words kept = cleaned words / raw words per clip (chunks the guard pasted raw count as kept). "
        "<75% and >130% are clips outside the casual guard band after guarding; a non-zero count "
        "means the guard fired per chunk while the whole clip still drifted._"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
