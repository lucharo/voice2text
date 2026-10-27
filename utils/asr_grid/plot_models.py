"""Chart for the docs: each speech model's errors against its wait, on real dictations
and on far-field meetings.

    .venv/bin/python utils/asr_grid/plot_models.py     # -> docs/images/models.svg

Numbers only, from the grid's finished cells: word error rate over the `wispr` set (208
of the maintainer's dictations, scored against silver.py's transcripts) and over
`ami-sdm` (150 AMI meeting clips on a room microphone, human labels), against the
median decode time after release on the grid. That is the whole file under 60 s; v2t
starts sooner on backends that cut pieces while the key is held (Core ML from 15 s,
Qwen3-ASR from 35 s), so its real wait there is shorter. Systems are taken with their `chunk` pass from 60 s up, as
v2t decodes long recordings. A self-contained SVG that follows the
reader's light or dark mode, like plot_wait.py.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import grid  # noqa: E402

OUT = grid.REPO / "docs/images/models.svg"
# system -> label; `default` and `qwen` get their own shape and colour
SYSTEMS = {
    "parakeet-v3-coreml": "Parakeet v3, Core ML (default)",
    "qwen3-asr-1.7b-8bit": "Qwen3-ASR 1.7B (qwen3-asr)",
    "parakeet-v3": "Parakeet v3, MLX bf16",
    "parakeet-unified-en": "Parakeet Unified EN, bf16",
    "whisper-turbo": "Whisper large-v3 turbo",
    "cohere-transcribe-vad": "Cohere Transcribe",
    "nemotron-3.5-stream": "Nemotron 3.5",
    "voxtral-rt-4bit": "Voxtral Mini 4B",
}
DEFAULT, QWEN = "parakeet-v3-coreml", "qwen3-asr-1.7b-8bit"
# v2t backends: from 60 s v2t decodes these in pieces, so a missing chunk pass is an error
# rather than a quiet fall back to the whole-file or stream text
NEEDS_CHUNKS = {DEFAULT, QWEN, "parakeet-v3", "parakeet-unified-en"}
PANELS = (
    ("wispr", "208 real dictations (errors against silver transcripts)", (0, 18)),
    ("ami-sdm", "150 meeting clips on a room microphone (human labels)", (20, 52)),
)
# label offsets in px (and anchor), per panel, where the default (8, 4) would collide
OFF = {
    ("wispr", "parakeet-v3-coreml"): (-4, 20),
    ("wispr", "qwen3-asr-1.7b-8bit"): (-11, 4, "end"),
    ("ami-sdm", "parakeet-unified-en"): (8, 14),
    ("ami-sdm", "parakeet-v3"): (8, -6),
    ("ami-sdm", "cohere-transcribe-vad"): (8, 14),
    ("wispr", "parakeet-v3"): (8, -6),
    ("wispr", "nemotron-3.5-stream"): (8, -6),
}
W, PH = 760, 300  # width, panel height
L, R, T, B = 58, 20, 34, 40
X0, X1 = math.log10(0.03), math.log10(3)


def X(v: float) -> float:
    return L + (math.log10(v) - X0) / (X1 - X0) * (W - L - R)


def rows_of(set_name: str, system: str) -> tuple[str, dict]:
    """A system's rows, with its chunk pass merged in when that pass is complete.

    That covers `hacky` Parakeet too: since 0.5.8 v2t decodes recordings from 60 s
    in pieces, not with the stream the `hacky` cell scores there.
    """
    rows = {r["id"]: r for r in grid.read_jsonl(grid.RESULTS / set_name / f"{system}.jsonl")}
    chunked = grid.RESULTS / set_name / f"{system}.chunked.jsonl"
    long = [k for k, r in rows.items() if r["duration_s"] >= grid.TAKEOVER_S]
    extra = {r["id"]: r for r in grid.read_jsonl(chunked)} if chunked.exists() else {}
    complete = grid.mode_of(system) in ("offline", "hacky") and all(k in extra for k in long)
    if long and not complete and system in NEEDS_CHUNKS:
        raise SystemExit(
            f"{set_name}: {system} needs its chunk pass for {len(long)} clips from 60 s "
            f"({sum(k in extra for k in long)} done): grid.py chunk --system {system} --set {set_name}"
        )
    if complete:
        return system + grid.CHUNKED, {k: {**r, **extra.get(k, {})} for k, r in rows.items()}
    return system, rows


def points(set_name: str) -> dict[str, tuple[float, float]]:
    clips = {c["id"]: c for c in grid.read_jsonl(grid.SETS / f"{set_name}.jsonl")}
    if set_name == "wispr":
        silver = {r["id"]: r["text"] for r in grid.read_jsonl(grid.GRID / "silver/wispr.jsonl")}
        clips = {k: {**c, "text": silver[k], "lang": "en"} for k, c in clips.items()}
    out = {}
    for system in SYSTEMS:
        name, rows = rows_of(set_name, system)
        if set(clips) - set(rows):
            raise SystemExit(f"{set_name}: {system} has not finished every clip")
        ref = err = 0
        waits = []
        for k, c in clips.items():
            truth = grid.normalise(c["text"], c["lang"])
            ref += len(truth)
            err += grid.edits(truth, grid.normalise(grid.final_text(name, rows[k]), c["lang"]), c["lang"])
            waits.append(grid.wait_s(name, rows[k]))
        out[system] = (100 * err / ref, float(np.median(waits)))
        print(f"{set_name:8} {system:24} WER {out[system][0]:5.2f}%  wait p50 {out[system][1]:.3f} s")
    return out


def panel(set_name: str, title: str, ylim: tuple[int, int], top: float) -> list[str]:
    lo, hi = ylim

    def Y(v: float) -> float:
        return top + PH - B - (v - lo) / (hi - lo) * (PH - T - B)

    out = [f'<text class="title" x="{L}" y="{top + 20}">{title}</text>']
    for t in (0.05, 0.1, 0.2, 0.5, 1, 2):
        out.append(f'<line class="grid" x1="{X(t):.1f}" x2="{X(t):.1f}" y1="{top + T}" y2="{top + PH - B}"/>')
        out.append(f'<text class="tick" x="{X(t):.1f}" y="{top + PH - B + 16}" text-anchor="middle">{t:g} s</text>')
    step = 4 if hi - lo <= 20 else 10
    for v in range(lo, hi + 1, step):
        out.append(f'<line class="grid" x1="{L}" x2="{W - R}" y1="{Y(v):.1f}" y2="{Y(v):.1f}"/>')
        out.append(f'<text class="tick" x="{L - 7}" y="{Y(v) + 4:.1f}" text-anchor="end">{v}%</text>')
    out.append(
        f'<text class="axis" transform="translate(14 {top + (T + PH - B) / 2}) rotate(-90)" '
        'text-anchor="middle">words wrong</text>'
    )
    for system, (wer, wait) in points(set_name).items():
        cx, cy = X(wait), Y(min(wer, hi))
        cls = "default" if system == DEFAULT else "qwen" if system == QWEN else "other"
        tip = f"<title>{SYSTEMS[system]}: {wer:.1f}% words wrong, {wait:.2f} s median wait</title>"
        if cls == "default":
            out.append(f'<rect class="dot {cls}" x="{cx - 5:.1f}" y="{cy - 5:.1f}" width="10" height="10">{tip}</rect>')
        elif cls == "qwen":
            out.append(
                f'<path class="dot {cls}" d="M{cx:.1f},{cy - 7:.1f}L{cx + 7:.1f},{cy:.1f}'
                f'L{cx:.1f},{cy + 7:.1f}L{cx - 7:.1f},{cy:.1f}Z">{tip}</path>'
            )
        else:
            out.append(f'<circle class="dot {cls}" cx="{cx:.1f}" cy="{cy:.1f}" r="4">{tip}</circle>')
        dx, dy, *anchor = OFF.get((set_name, system), (8, 4))
        out.append(
            f'<text class="lab {cls}" x="{cx + dx:.1f}" y="{cy + dy:.1f}" '
            f'text-anchor="{anchor[0] if anchor else "start"}">{SYSTEMS[system]}  {wer:.1f}%</text>'
        )
    return out


def main() -> int:
    height = PH * len(PANELS) + 30
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {height}" width="{W}" height="{height}" '
        'font-family="system-ui,-apple-system,Segoe UI,sans-serif">',
        "<style>"
        ".bg{fill:#fcfcfb}.grid{stroke:#ecebe7}.tick{fill:#8a8984;font-size:11px}"
        ".axis{fill:#52514e;font-size:12px}.title{fill:#0b0b0b;font-size:14px;font-weight:600}"
        ".lab{font-size:11.5px}.lab.default,.lab.qwen{font-weight:600}"
        ".default{fill:#eb6834}.qwen{fill:#2a78d6}.other{fill:#8a8984}.dot{stroke:#fcfcfb;stroke-width:1.5}"
        "@media (prefers-color-scheme:dark){.bg{fill:#1a1a19}.grid{stroke:#2a2a28}"
        ".tick{fill:#8f8e86}.axis{fill:#c3c2b7}.title{fill:#fff}.default{fill:#d95926}"
        ".qwen{fill:#3987e5}.other{fill:#8f8e86}.dot{stroke:#1a1a19}}"
        "</style>",
        f'<rect class="bg" width="{W}" height="{height}"/>',
    ]
    for i, (set_name, title, ylim) in enumerate(PANELS):
        out += panel(set_name, title, ylim, i * PH)
    out.append(
        f'<text class="axis" x="{(L + W - R) / 2}" y="{height - 12}" text-anchor="middle">'
        "median decode time after release on the grid (log scale); lower left is better</text>"
    )
    out.append("</svg>")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(out) + "\n")
    print(OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
