# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pyarrow", "scipy", "soundfile"]
# ///
"""Fetch the meeting and earnings-call sets the grid adds, ours and the Open ASR Leaderboard's.

Maintainer-only. Writes 16 kHz WAVs plus `transcripts.tsv` (id, text) under
~/.v2t/eval/labelled/<set>/; `grid.py prepare` then builds the manifests from those.

    uv run --script utils/asr_grid/fetch_noisy.py            # every set below
    uv run --script utils/asr_grid/fetch_noisy.py ami-ihm    # one set
    uv run --script utils/asr_grid/fetch_noisy.py --full ami-ihm   # all 7,805 clips too

- ami-sdm: AMI meetings on the single distant (room) microphone, as a laptop hears a meeting
  (edinburghcstr/ami, config sdm, test, CC-BY-4.0). One Parquet shard, so three meetings;
  150 seeded clips of 2 to 35 s. The leaderboard does not use this microphone.
- ami-ihm: the leaderboard's own AMI, `AMI-Cleaned`: each speaker's headset microphone, clips
  under 1 s removed (hf-audio/open-asr-leaderboard, config ami_cleaned, all 16 test meetings).
  150 clips seeded across the whole split; `--full` also writes all of them to `audio-full/`.
- earnings22: earnings calls cut into short chunks with their original transcripts
  (distil-whisper/earnings22, config chunked). One shard, three calls, 150 seeded clips.
- earnings22-aa: the leaderboard's `Earnings22-Cleaned-AA-chunked`: 6 calls (115 min) in 341
  chunks, transcripts corrected by Artificial Analysis. All of it; scored per call, the chunks'
  text joined in order against the call's transcript (`parents.tsv`), as the leaderboard does.
"""

from __future__ import annotations

import io
import json
import random
import sys
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
        partial = shard.with_suffix(".parquet.part")
        urllib.request.urlretrieve(url, partial)
        pq.read_metadata(partial)  # a cut-off download fails here, not on every later run
        partial.replace(shard)
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


LB_AMI = "https://huggingface.co/api/datasets/hf-audio/open-asr-leaderboard/parquet/ami_cleaned/test/{}.parquet"
AA = "https://huggingface.co/datasets/ArtificialAnalysis/{}/resolve/main/{}"


def _download(url: str, dest: Path) -> Path:
    if not dest.exists():
        print(f"downloading {url}")
        partial = dest.with_suffix(dest.suffix + ".part")
        urllib.request.urlretrieve(url, partial)
        partial.replace(dest)
    return dest


def _wav16(data_bytes: bytes) -> np.ndarray:
    data, rate = sf.read(io.BytesIO(data_bytes), dtype="float32", always_2d=True)
    data = data.mean(axis=1)
    return resample_poly(data, RATE, rate).astype(np.float32) if rate != RATE else data


def fetch_ami_ihm(full: bool) -> None:
    """A seeded sample of the leaderboard's AMI-Cleaned, from every test meeting."""
    out = LABELLED / "ami-ihm"
    (out / "audio").mkdir(parents=True, exist_ok=True)
    rows = []
    for shard in range(3):
        path = _download(LB_AMI.format(shard), out / f"test-{shard}.parquet")
        rows += pq.read_table(path, columns=["id", "text"]).to_pylist()
    ids = sorted(r["id"] for r in rows)
    random.Random(SEED).shuffle(ids)
    keep = set(ids[:SAMPLE])
    text = {r["id"]: r["text"] for r in rows}
    full_dir = out / "audio-full"
    if full:
        full_dir.mkdir(exist_ok=True)
    for shard in range(3):
        for r in pq.read_table(out / f"test-{shard}.parquet", columns=["id", "audio"]).to_pylist():
            dirs = ([out / "audio"] if r["id"] in keep else []) + ([full_dir] if full else [])
            if dirs:
                data = _wav16(r["audio"]["bytes"])
                for d in dirs:
                    sf.write(str(d / f"{r['id']}.wav"), data, RATE, subtype="PCM_16")
    (out / "transcripts.tsv").write_text("".join(f"{i}\t{text[i]}\n" for i in sorted(keep)))
    if full:
        (out / "transcripts-full.tsv").write_text("".join(f"{i}\t{text[i]}\n" for i in sorted(text)))
    print(f"ami-ihm: {len(keep)} of {len(rows)} clips{' (and all of them in audio-full/)' if full else ''} -> {out}")


def fetch_earnings22_aa() -> None:
    """All of the leaderboard's Earnings22-Cleaned-AA-chunked, with each call's transcript."""
    out = LABELLED / "earnings22-aa"
    (out / "audio").mkdir(parents=True, exist_ok=True)
    meta = _download(AA.format("Earnings22-Cleaned-AA-chunked", "earnings22_cleaned_aa_chunked_v1.jsonl"),
                     out / "chunks.jsonl")
    parents = _download(AA.format("Earnings22-Cleaned-AA", "earnings22_cleaned_aa_v1.jsonl"), out / "parents.jsonl")
    chunks = [json.loads(line) for line in meta.read_text().splitlines() if line]
    for c in chunks:
        wav = out / "audio" / c["file_name"]
        if not wav.exists():
            url = AA.format("Earnings22-Cleaned-AA-chunked", f"audio/{c['file_name']}")
            for attempt in range(3):  # 341 small downloads: retry a dropped connection
                try:
                    with urllib.request.urlopen(url, timeout=60) as resp:
                        sf.write(str(wav), _wav16(resp.read()), RATE, subtype="PCM_16")
                    break
                except OSError:
                    if attempt == 2:
                        raise
    (out / "chunks.tsv").write_text(
        "".join(f"{c['file_name'].removesuffix('.wav')}\t{c['parent_id']}\t{c['chunk_index']}\n" for c in chunks)
    )
    calls = [json.loads(line) for line in parents.read_text().splitlines() if line]
    (out / "parents.tsv").write_text("".join(f"{p['id']}\t{' '.join(p['transcript'].split())}\n" for p in calls))
    print(f"earnings22-aa: {len(chunks)} chunks of {len(calls)} calls -> {out}")


if __name__ == "__main__":
    args = sys.argv[1:]
    full = "--full" in args
    names = [a for a in args if a != "--full"] or [*SETS, "ami-ihm", "earnings22-aa"]
    for name in names:
        if name in SETS:
            fetch(name, *SETS[name])
        elif name == "ami-ihm":
            fetch_ami_ihm(full)
        elif name == "earnings22-aa":
            fetch_earnings22_aa()
        else:
            raise SystemExit(f"unknown set {name}")
