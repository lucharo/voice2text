# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pyarrow", "scipy", "soundfile"]
# ///
"""Fetch the two noisy labelled sets the grid adds: AMI far-field and Earnings22.

Maintainer-only. Downloads one Parquet shard of each test split from Hugging Face's
Parquet conversion, keeps a seeded sample of 150 clips of 2 to 35 s, and writes them
as 16 kHz WAVs plus `transcripts.tsv` (id, text) under ~/.v2t/eval/labelled/<set>/.
`grid.py prepare` then builds the `ami-sdm` and `earnings22` manifests from those.

    uv run --script utils/asr_grid/fetch_noisy.py

- ami-sdm: AMI meetings on the single distant (room) microphone, test split
  (edinburghcstr/ami, config sdm, CC-BY-4.0): far-field, overlapping speech, um/uh.
- earnings22: earnings calls cut into short chunks (distil-whisper/earnings22,
  config chunked, the Open ASR Leaderboard's source): phone quality, accents,
  company names and numbers.
"""

from __future__ import annotations

import io
import random
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
from scipy.signal import resample_poly

LABELLED = Path.home() / ".v2t/eval/labelled"
SAMPLE, SEED, RATE = 150, 20260929, 16000
SETS = {
    "ami-sdm": ("https://huggingface.co/api/datasets/edinburghcstr/ami/parquet/sdm/test/0.parquet", "text"),
    "earnings22": (
        "https://huggingface.co/api/datasets/distil-whisper/earnings22/parquet/chunked/test/0.parquet",
        "transcription",
    ),
}


def fetch(name: str, url: str, text_col: str) -> None:
    out = LABELLED / name
    (out / "audio").mkdir(parents=True, exist_ok=True)
    shard = out / "test-0.parquet"
    if not shard.exists():
        print(f"{name}: downloading {url}")
        urllib.request.urlretrieve(url, shard)
    table = pq.read_table(shard)
    cols = table.column_names
    text_col = text_col if text_col in cols else next(c for c in cols if c in ("text", "transcription", "sentence"))
    id_col = next((c for c in ("id", "audio_id", "segment_id", "file_id") if c in cols), None)
    rows = table.to_pylist()
    ids = [str(r[id_col]) for r in rows] if id_col else []
    unique_ids = len(set(ids)) == len(ids) > 0  # Earnings22's ids repeat across chunks
    candidates = []
    for i, row in enumerate(rows):
        audio = row["audio"]
        data, rate = sf.read(io.BytesIO(audio["bytes"]), dtype="float32", always_2d=True)
        data = data.mean(axis=1)
        if rate != RATE:
            data = resample_poly(data, RATE, rate).astype(np.float32)
        seconds = len(data) / RATE
        text = (row[text_col] or "").strip()
        if 2 <= seconds <= 35 and text and not text.startswith("<"):
            cid = str(row[id_col]) if unique_ids else f"{name}-{i:05d}"
            candidates.append((cid.replace("/", "_"), data, text))
    random.Random(SEED).shuffle(candidates)
    picked = sorted(candidates[:SAMPLE], key=lambda c: c[0])
    lines = []
    for cid, data, text in picked:
        sf.write(str(out / "audio" / f"{cid}.wav"), data, RATE, subtype="PCM_16")
        lines.append(f"{cid}\t{text}")
    (out / "transcripts.tsv").write_text("\n".join(lines) + "\n")
    hours = sum(len(d) for _, d, _ in picked) / RATE / 3600
    print(f"{name}: {len(picked)} of {len(candidates)} eligible clips, {hours:.2f} h -> {out}")


if __name__ == "__main__":
    for name, (url, col) in SETS.items():
        fetch(name, url, col)
