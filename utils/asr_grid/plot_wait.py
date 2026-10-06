"""Chart for the README: wait after release against dictation length, Parakeet v3.

    python utils/asr_grid/plot_wait.py                 # -> docs/images/wait-vs-length.svg

One dot per dictation in the grid's `wispr` results (numbers only, no text): the
whole-file read after release for every length, and v2t's streamed draft from 60 s
up. A self-contained SVG that follows the reader's light or dark mode.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import grid  # noqa: E402

OUT = grid.REPO / "docs/images/wait-vs-length.svg"
W, H = 760, 400
L, R, T, B = 58, 20, 40, 46
X0, X1 = math.log10(1), math.log10(1000)
Y0, Y1 = math.log10(0.05), math.log10(300)


def X(v: float) -> float:
    return L + (math.log10(v) - X0) / (X1 - X0) * (W - L - R)


def Y(v: float) -> float:
    return H - B - (math.log10(max(v, 0.05)) - Y0) / (Y1 - Y0) * (H - T - B)


def main() -> int:
    rows = grid.read_jsonl(grid.RESULTS / "wispr/parakeet-v3.jsonl")
    whole = [(r["duration_s"], r["offline_s"]) for r in rows]
    streamed = [
        (r["duration_s"], r["stream_wait_s"])
        for r in rows
        if r["duration_s"] >= grid.TAKEOVER_S
    ]
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
        'font-family="system-ui,-apple-system,Segoe UI,sans-serif">',
        "<style>"
        ".bg{fill:#fcfcfb}.grid{stroke:#ecebe7}.rule{stroke:#8a8984;stroke-dasharray:4 3}"
        ".tick{fill:#8a8984;font-size:11px}.axis{fill:#52514e;font-size:12px}"
        ".title{fill:#0b0b0b;font-size:15px;font-weight:600}.lab{font-size:12px;font-weight:600}"
        ".whole{fill:#eb6834}.stream{fill:#2a78d6}.dot{stroke:#fcfcfb;stroke-width:1.5}"
        "@media (prefers-color-scheme:dark){.bg{fill:#1a1a19}.grid{stroke:#2a2a28}"
        ".tick{fill:#8f8e86}.axis{fill:#c3c2b7}.title{fill:#fff}.whole{fill:#d95926}"
        ".stream{fill:#3987e5}.dot{stroke:#1a1a19}}"
        "</style>",
        f'<rect class="bg" width="{W}" height="{H}"/>',
        f'<text class="title" x="{L}" y="22">Wait after you let go, by dictation length '
        f"(Parakeet v3, {len(rows)} real dictations)</text>",
    ]
    for t in (10, 30, 60, 120, 300, 600):
        out.append(
            f'<line class="grid" x1="{X(t):.1f}" x2="{X(t):.1f}" y1="{T}" y2="{H - B}"/>'
        )
        out.append(
            f'<text class="tick" x="{X(t):.1f}" y="{H - B + 16}" text-anchor="middle">{t} s</text>'
        )
    for t in (0.1, 0.3, 1, 3, 10, 30, 100):
        out.append(
            f'<line class="grid" x1="{L}" x2="{W - R}" y1="{Y(t):.1f}" y2="{Y(t):.1f}"/>'
        )
        out.append(
            f'<text class="tick" x="{L - 7}" y="{Y(t) + 4:.1f}" text-anchor="end">{t:g} s</text>'
        )
    out.append(
        f'<line class="rule" x1="{X(60):.1f}" x2="{X(60):.1f}" y1="{T}" y2="{H - B}"/>'
    )
    out.append(
        f'<text class="tick" x="{X(60) + 5:.1f}" y="{T + 12}">60 s: v2t switches to the streamed draft</text>'
    )
    out.append(
        f'<text class="axis" x="{(L + W - R) / 2}" y="{H - 8}" text-anchor="middle">dictation length (log scale)</text>'
    )
    out.append(
        f'<text class="axis" transform="translate(14 {(T + H - B) / 2}) rotate(-90)" text-anchor="middle">wait (log scale)</text>'
    )
    for d, w in whole:
        out.append(
            f'<circle class="dot whole" cx="{X(d):.1f}" cy="{Y(w):.1f}" r="4"><title>{d:.0f} s, whole file: {w:.2f} s</title></circle>'
        )
    for d, w in streamed:
        cx, cy = X(d), Y(w)
        out.append(
            f'<path class="dot stream" d="M{cx:.1f},{cy - 5:.1f}L{cx + 4.6:.1f},{cy + 3:.1f}'
            f'L{cx - 4.6:.1f},{cy + 3:.1f}Z"><title>{d:.0f} s, streamed draft: {w:.2f} s</title></path>'
        )
    out.append(
        f'<text class="lab whole" x="{X(45):.1f}" y="{Y(12):.1f}" text-anchor="end">● read the whole file after release</text>'
    )
    out.append(
        f'<text class="lab stream" x="{X(950):.1f}" y="{Y(0.12):.1f}" text-anchor="end">▲ keep the streamed draft (from 60 s)</text>'
    )
    out.append("</svg>")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(out) + "\n")
    print(OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
