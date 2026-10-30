# /// script
# requires-python = ">=3.11"
# dependencies = ["matplotlib", "numpy", "kaldialign>=0.12", "num2words", "regex"]
# ///
"""Two Pareto panels from the grid: WER against weights on disk, and against the wait
after release. Short labelled sets only (ls-clean, ls-other, fleurs-es: 450 clips of
2 to 35 s), which is what a typical dictation looks like.

    uv run --script utils/asr_grid/plot_pareto.py      # -> ~/.v2t/eval/grid/<date>-pareto.png

WER is the mean of the three sets' WERs, scored by `grid.score_set` exactly as the
report scores them; an English-only system's mean covers its two English sets and its
label says so. Wait is the median over the same clips. Sizes are the published weight
files (the sum of `*.safetensors` / `*.npz` / `*.tar.zst` sizes from
https://huggingface.co/api/models/<repo>/tree/main, read 2026-10-14).
"""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import grid  # noqa: E402

SETS = ("ls-clean", "ls-other", "fleurs-es")
# system -> (label, GB on disk as published); systems not here are not drawn
# (the mlx-audio runs of v3 and Whisper are the same weights as their originals,
# and phonon-2-packed is phonon-2's weights with the encoder left packed)
SYSTEMS = {
    # bf16: v2t loads it 8-bit since 0.5.15, which the grid turns off
    "parakeet-v3": ("Parakeet v3 (bf16 reference)", 2.508),
    "parakeet-ultra": ("Parakeet Ultra", 1.254),
    "whisper-turbo": ("Whisper large-v3 turbo", 1.614),
    "nemotron-3.5-stream": ("Nemotron 3.5 ASR streaming 0.6B", 1.276),
    "voxtral-rt-4bit": ("Voxtral Mini 4B RT (4-bit)", 3.134),
    "qwen3-asr-1.7b": ("Qwen3-ASR 1.7B (bf16)", 4.076),
    "qwen3-asr-1.7b-8bit": ("Qwen3-ASR 1.7B (8-bit)", 2.463),
    "cohere-transcribe": ("Cohere Transcribe 2B", 4.132),
    "parakeet-redux": ("Parakeet Redux", 0.178),
    "parakeet-unified-en": ("Parakeet Unified EN", 2.474),
    "phonon-2": ("Phonon-2", 0.164),
    # v2t's default since the Core ML backend: the same v3 weights, int8 encoder
    "parakeet-v3-coreml": ("Parakeet v3 Core ML (v2t default)", 0.633),
    # Nemotron-Labs Unified ASR through FluidAudio (the files models.toml lists)
    "nemotron-unified": ("Nemotron-Labs Unified ASR 0.6B (fp16)", 1.223),
    "nemotron-unified-int8": ("Nemotron-Labs Unified ASR 0.6B (int8)", 0.627),
    "nemotron-unified-stream-1.12": ("Nemotron-Labs Unified ASR 0.6B, 1.12 s stream", 1.212),
}
PHONE = {"parakeet-redux", "phonon-2"}  # the small on-device candidates
NEW = {"nemotron-unified", "nemotron-unified-int8", "nemotron-unified-stream-1.12"}
# label offsets in points, per panel; tuned by eye on the rendered PNG
OFF = {
    ("gb", "parakeet-ultra"): (-20, -16),
    ("gb", "whisper-turbo"): (-60, 9),
    ("gb", "qwen3-asr-1.7b-8bit"): (-70, -18),
    ("gb", "qwen3-asr-1.7b"): (-20, 9),
    ("wait", "parakeet-ultra"): (8, -14),
    ("wait", "qwen3-asr-1.7b-8bit"): (8, -14),
    ("wait", "qwen3-asr-1.7b"): (2, -18),
    ("wait", "phonon-2"): (8, 5),
    ("wait", "cohere-transcribe"): (8, 0),
    ("wait", "parakeet-unified-en"): (8, -14),
    ("gb", "nemotron-unified-int8"): (-120, -18),
    ("gb", "nemotron-unified"): (-20, 42),
    ("gb", "nemotron-unified-stream-1.12"): (8, -18),
    ("wait", "nemotron-unified-int8"): (-10, 20),
    ("wait", "nemotron-unified"): (8, 4),
    ("wait", "parakeet-v3"): (-165, 6),
    ("wait", "nemotron-unified-stream-1.12"): (8, -18),
}
YMAX = 5.6


def points() -> tuple[dict[str, dict], float | None]:
    # only sets whose every cell finished every clip (see grid.incomplete_cells)
    rows = {}
    for s in SETS:
        if short := grid.incomplete_cells(s):
            raise SystemExit(f"{s}: unfinished cells {short}; finish or remove them")
        rows[s] = {r["system"]: r for r in grid.score_set(s)}
    # what an English-only mean is comparable with: v3 on the same two sets
    v3 = [rows[s]["parakeet-v3"]["wer"] for s in SETS[:2] if "parakeet-v3" in rows[s]]
    v3_en = 100 * float(np.mean(v3)) if len(v3) == 2 else None
    out = {}
    for system, (label, gb) in SYSTEMS.items():
        cells = [rows[s][system] for s in SETS if system in rows[s]]
        if not cells:
            continue
        english_only = system in grid.ENGLISH_ONLY
        if len(cells) < (2 if english_only else 3):
            continue  # a cell missing: no comparable mean
        wer = 100 * float(np.mean([c["wer"] for c in cells]))
        wait = float(np.median([w for c in cells for w in c["waits"]]))
        peak = max(
            (c["peak_gb"] for c in cells if c["peak_gb"] is not None), default=None
        )
        if english_only:
            label += " (EN, 2 sets)"
        out[system] = dict(
            label=label, gb=gb, wer=wer, wait=wait, peak=peak, en=english_only
        )
        print(
            f"{label:38} {gb:6.3f} GB  WER {wer:.2f}%  wait p50 {wait:.3f}s"
            + (f"  peak {peak:.2f} GB" if peak else "")
        )
    packed = [rows[s].get("phonon-2-packed") for s in SETS[:2]]
    if "phonon-2" in out and all(packed):
        out["phonon-2"]["packed_peak"] = max(c["peak_gb"] for c in packed)
    return out, v3_en


def front(pts: list[dict], key: str) -> list[dict]:
    """Lower-left Pareto front on (key, wer)."""
    best, out = float("inf"), []
    for p in sorted(pts, key=lambda p: (p[key], p["wer"])):
        if p["wer"] < best:
            out.append(p)
            best = p["wer"]
    return out


def main() -> None:
    pts, v3_en = points()
    plt.rcParams.update({"font.size": 11, "font.family": "Helvetica Neue"})
    fig, axes = plt.subplots(1, 2, figsize=(15, 6.8), dpi=200)
    for ax, key, xlabel in (
        (axes[0], "gb", "Weights to download (GB, as published, log scale)"),
        (axes[1], "wait", "Wait after you let go of the key, median (s, log scale)"),
    ):
        # the front only joins means over the same three sets
        f = front([p for p in pts.values() if not p["en"]], key)
        ax.plot(
            [p[key] for p in f],
            [min(p["wer"], YMAX) for p in f],
            "-",
            color="#2a9d8f",
            lw=2,
            alpha=0.5,
            zorder=1,
        )
        for system, p in pts.items():
            shipped = system == "parakeet-v3"
            colour = "#e76f51" if shipped else ("#2a9d8f" if p in f else "#9aa5b1")
            marker = "*" if system in PHONE else ("D" if system in NEW else "o")
            size = 170 if shipped else (260 if system in PHONE else 90)
            if p["en"]:  # hollow: a two-set mean, read against the dashed line
                ax.scatter(
                    p[key],
                    p["wer"],
                    s=size,
                    marker=marker,
                    zorder=3,
                    facecolor="white",
                    edgecolor="#264653",
                    linewidth=1.6,
                )
            else:
                ax.scatter(
                    p[key],
                    min(p["wer"], YMAX),
                    s=size,
                    marker=marker,
                    zorder=3,
                    color=colour,
                    edgecolor="black" if shipped else "none",
                )
            label = p["label"]
            if system in PHONE:
                label += f"\n{p['gb'] * 1000:.0f} MB, peak {p['peak']:.2f} GB"
                if "packed_peak" in p:
                    label += f" ({p['packed_peak']:.2f} packed)"
            if p["wer"] > YMAX:
                label += f": {p['wer']:.1f}% (off chart)"
            ax.annotate(
                label,
                (p[key], min(p["wer"], YMAX)),
                textcoords="offset points",
                xytext=OFF.get((key, system), (8, 5)),
                fontsize=9.5,
                fontweight="bold" if shipped or system in PHONE else "normal",
            )
        if v3_en is not None:
            ax.axhline(v3_en, ls="--", lw=1, color="#264653", alpha=0.6, zorder=0)
            ax.annotate(
                f"Parakeet v3 on the two English sets only: {v3_en:.2f}%",
                (0.01 if key == "gb" else 0.99, v3_en),
                xycoords=("axes fraction", "data"),
                xytext=(0, 4),
                textcoords="offset points",
                fontsize=9,
                color="#264653",
                ha="left" if key == "gb" else "right",
            )
        ax.set_xscale("log")
        ax.xaxis.set_minor_formatter(plt.NullFormatter())
        ticks = [0.1, 0.2, 0.5, 1, 2, 5] if key == "gb" else [0.05, 0.1, 0.2, 0.5, 1]
        ax.set_xticks(ticks)
        ax.get_xaxis().set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:g}"))
        ax.set_ylim(top=YMAX + 0.15)
        ax.set_xlabel(xlabel)
        ax.set_ylabel("WER, mean of the sets run (%), lower is better")
        ax.grid(alpha=0.25)
        ax.spines[["top", "right"]].set_visible(False)
    axes[0].set_title("Accuracy vs storage", loc="left", fontweight="bold")
    axes[1].set_title("Accuracy vs speed", loc="left", fontweight="bold")
    handles = [
        plt.Line2D([], [], color="#2a9d8f", lw=2, alpha=0.5, label="Pareto front"),
        plt.Line2D(
            [],
            [],
            ls="",
            marker="*",
            ms=14,
            color="#9aa5b1",
            label="phone candidate (size, MLX peak memory)",
        ),
        plt.Line2D(
            [],
            [],
            ls="",
            marker="D",
            ms=8,
            color="#9aa5b1",
            label="Nemotron-Labs Unified ASR 0.6B, FluidAudio (added 2026-10-29)",
        ),
        plt.Line2D(
            [],
            [],
            ls="",
            marker="o",
            ms=8,
            mfc="white",
            mec="#264653",
            label="English only: mean of 2 sets, compare with the dashed line",
        ),
    ]
    fig.legend(handles=handles, loc="lower center", ncol=4, frameon=False, fontsize=9.5)
    fig.suptitle(
        "v2t speech-to-text grid · M4 Pro 48 GB · 450 labelled clips (LibriSpeech clean + "
        "other, FLEURS Spanish), 2–35 s",
        x=0.01,
        ha="left",
        fontsize=12,
        color="#444",
    )
    fig.tight_layout(rect=(0, 0.05, 1, 0.95))
    out = grid.GRID / f"{date.today().isoformat()}-pareto.png"
    fig.savefig(out)
    print(out)


if __name__ == "__main__":
    main()
