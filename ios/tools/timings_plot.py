# /// script
# requires-python = ">=3.11"
# dependencies = ["matplotlib"]
# ///
"""Plot the iPhone app's dictation timings against dictation length (#122).

    uv run ios/tools/timings_plot.py timings.csv [-o timings.png]

timings.csv is what History's "Copy timings" puts on the clipboard (paste it into a file on the Mac): one row
per dictation with its length, the time from Done to the transcript, cleanup's time (blank when it did not
run) and the time from Done to the text being sent to the keyboard. Prints the median of each per length band
and draws the three against length on a log axis. Only dictations saved since #123 have timings.
"""

from __future__ import annotations

import argparse
import csv
import statistics
from pathlib import Path

BANDS = [(0, 15), (15, 30), (30, 60), (60, 120), (120, 300), (300, 1e9)]


def load(path: Path) -> list[dict]:
    rows = []
    with path.open(newline="") as f:
        for r in csv.DictReader(f):
            rows.append({
                "audio": float(r["audio_s"]),
                "speech": float(r["speech_s"]),
                "cleanup": float(r["cleanup_s"]) if r["cleanup_s"] else None,
                "total": float(r["total_s"]),
            })
    return rows


def table(rows: list[dict]) -> str:
    out = ["| length | dictations | speech p50 | cleanup p50 | Done to text p50 |", "|---|--:|--:|--:|--:|"]
    for lo, hi in BANDS:
        b = [r for r in rows if lo <= r["audio"] < hi]
        if not b:
            continue
        cleanups = [r["cleanup"] for r in b if r["cleanup"] is not None]
        label = f"{lo:g}-{hi:g} s" if hi < 1e9 else f"{lo:g} s+"
        cl = f"{statistics.median(cleanups):.2f} s" if cleanups else "–"
        out.append(f"| {label} | {len(b)} | {statistics.median(r['speech'] for r in b):.2f} s | {cl} | "
                   f"{statistics.median(r['total'] for r in b):.2f} s |")
    return "\n".join(out)


def plot(rows: list[dict], path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(7, 4.2), dpi=200)
    x = [r["audio"] for r in rows]
    ax.scatter(x, [r["total"] for r in rows], s=10, c="#202124", label="Done to text")
    ax.scatter([r["audio"] for r in rows if r["cleanup"] is not None],
               [r["cleanup"] for r in rows if r["cleanup"] is not None], s=10, c="#1a73e8", label="cleanup")
    ax.scatter(x, [r["speech"] for r in rows], s=10, c="#d93025", label="speech")
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("dictation length (s)")
    ax.set_ylabel("seconds after Done, on the iPhone")
    ax.grid(alpha=0.3, which="both", lw=0.4)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(path)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("csv", type=Path)
    p.add_argument("-o", "--out", type=Path)
    a = p.parse_args()
    rows = load(a.csv)
    print(table(rows))
    if a.out:
        plot(rows, a.out)


if __name__ == "__main__":
    main()
