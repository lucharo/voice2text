"""How long is the wait after Stop when settled sentences are cleaned while recording?

Maintainer-only, not packaged. Replays the raw text of real dictations from the history
database (``~/.v2t/history/history.sqlite``, pasted rows of at least ``--min-audio`` seconds)
through the shipped cleanup two ways, interleaved per dictation so machine load hits both:

- ``batch``: the whole raw text cleaned after Stop, as v2t did up to this change.
- ``streaming``: ``backends.CleanupStream`` hands out settled segments as each piece but
  the last arrives, each cleaned "while recording"; after Stop only ``rest`` is cleaned.

History keeps the joined transcript, not each piece's text, so pieces are rebuilt by cutting
the words at the dictation's own speaking rate with its backend's piece rule (``CUTS``), and the
cleanups are laid on a clock so a segment still cleaning at Stop counts toward the wait. Real cuts
fall in pauses, so real pieces end at sentence ends more often than these; the segment
boundaries are therefore approximate, the per-chunk model cost is not.

    uv run python utils/cleanup_speed/bench_streaming.py --limit 5   # smoke
    uv run python utils/cleanup_speed/bench_streaming.py             # every long dictation

Writes ``~/.v2t/eval/cleanup-stream/<date>-report.md`` (numbers only) and a private
per-dictation ``results.jsonl``. Run it alone on the GPU; the report logs the load average.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import sqlite3
import statistics
import sys
from datetime import date
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from v2t import backends, config, coreml  # noqa: E402

HISTORY = Path.home() / ".v2t/history/history.sqlite"
OUT = Path.home() / ".v2t/eval/cleanup-stream"


def q(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))]


# Each backend's piece rule (PieceDecoder's piece_s, search_s, whole_s): the Core ML default
# cuts 12 s pieces from the start (coreml.PIECE_S); Parakeet on MLX decodes whole under
# WHOLE_FILE_S, then cuts 30 s pieces; Whisper has no piece decoder (None: one piece at Stop).
CUTS = {
    "parakeet-coreml": (coreml.PIECE_S, coreml.PIECE_SEARCH_S, 0.0),
    "parakeet": (backends.PIECE_S, backends.PIECE_SEARCH_S, backends.WHOLE_FILE_S),
    "qwen3-asr": (backends.PIECE_S, backends.PIECE_SEARCH_S, 0.0),
    "whisper": None,
}


def rebuild_pieces(raw: str, audio_s: float, backend: str) -> list[tuple[float, str]]:
    """(when the piece is decoded, its words): the raw words cut every piece_s at the
    dictation's own speaking rate, each known search_s after its mark. Under whole_s
    the recording is one piece, decoded at Stop."""
    if CUTS[backend] is None:
        return [(audio_s, raw)]
    piece_s, search_s, whole_s = CUTS[backend]
    words = raw.split()
    if audio_s < max(whole_s, piece_s + search_s):
        return [(audio_s, raw)]
    per_piece = max(1, round(len(words) * piece_s / audio_s))
    pieces = []
    for n, i in enumerate(range(0, len(words), per_piece), 1):
        at = max(whole_s, n * piece_s + search_s)  # no cut before whole_s
        pieces.append((at if at < audio_s else audio_s, " ".join(words[i : i + per_piece])))
    return pieces


def batch(engine, raw: str, mode: str) -> tuple[str, float, int]:
    text, _ttft, seconds = engine.cleanup(raw, mode)
    return text, seconds, engine.last_stats["chunks"]


def streaming(engine, raw: str, pieces: list[tuple[float, str]], audio_s: float, mode: str) -> dict:
    """Clean as the app does: after each piece decoded before Stop, the next settled
    segment, one at a time, on a clock in audio seconds; at Stop, whatever segment is
    still being cleaned finishes, then the rest."""
    stream = backends.CleanupStream()
    parts, during, chunks, clock = [], 0.0, 0, 0.0
    for k, (at, _text) in enumerate(pieces, 1):
        # the processing thread decodes a piece once it is free; from Stop on nothing is cleaned early
        if max(clock, at) >= audio_s:
            break
        segment = stream.next([t for _at, t in pieces[:k]])
        if segment is None:
            continue
        text, _ttft, seconds = engine.cleanup(segment, mode)
        parts.append(text or segment)
        during += seconds
        clock = max(clock, at) + seconds
        chunks += engine.last_stats["chunks"]
    rest = stream.rest(raw)
    if rest is None:
        raise SystemExit("rebuilt pieces do not join to the raw text")
    after, after_chunks = 0.0, 0
    if rest:
        text, _ttft, after = engine.cleanup(rest, mode)
        parts.append(text or rest)
        after_chunks = engine.last_stats["chunks"]
    overhang = max(0.0, clock - audio_s)  # a segment still cleaning at Stop
    return {
        "text": " ".join(parts).strip(),
        "during_s": during,
        "after_s": overhang + after,
        "total_s": during + after,
        "chunks": chunks + after_chunks,
        "after_chunks": after_chunks,
        "early_words": len(stream.taken),
    }


def report(results: list[dict], model: str) -> None:
    b_after = [r["batch_s"] for r in results]
    s_after = [r["stream_after_s"] for r in results]
    s_total = [r["stream_total_s"] for r in results]
    early = [r["early_words"] / r["words"] for r in results]
    same = sum(r["identical"] for r in results)
    sims = [r["similarity"] for r in results]
    loads = [r["load"] for r in results]
    lines = [
        f"# Batch vs streaming cleanup, {date.today().isoformat()}",
        "",
        f"{len(results)} dictations from history, {min(r['audio_s'] for r in results):.0f} to "
        f"{max(r['audio_s'] for r in results):.0f} s of audio, {model}, pieces rebuilt with each "
        f"dictation's backend cuts at its speaking rate. "
        f"1-minute load average {min(loads):.0f} to {max(loads):.0f} on {os.cpu_count()} cores.",
        "",
        "| seconds | p50 | p90 | max | mean |",
        "|---|--:|--:|--:|--:|",
    ]
    for name, v in (
        ("batch: wait after Stop", b_after),
        ("streaming: wait after Stop", s_after),
        ("streaming: all cleanup, during + after", s_total),
    ):
        lines.append(
            f"| {name} | {q(v, 0.5):.2f} | {q(v, 0.9):.2f} | {max(v):.2f} | {statistics.fmean(v):.2f} |"
        )
    lines += [
        "",
        f"Words cleaned while recording: median {q(early, 0.5):.0%} of each dictation.",
        f"Text identical to batch: {same}/{len(results)}; word-level similarity median "
        f"{q(sims, 0.5):.3f}, lowest {min(sims):.3f}.",
        "",
        "| history id | audio s | words | chunks batch / stream | batch wait s | streaming wait s | cleaned early | similarity |",
        "|--:|--:|--:|--:|--:|--:|--:|--:|",
    ]
    for r in sorted(results, key=lambda r: -r["audio_s"])[:10]:
        lines.append(
            f"| {r['id']} | {r['audio_s']:.0f} | {r['words']} | {r['batch_chunks']} / "
            f"{r['stream_chunks']} | {r['batch_s']:.2f} | {r['stream_after_s']:.2f} | "
            f"{r['early_words'] / r['words']:.0%} | {r['similarity']:.3f} |"
        )
    path = OUT / f"{date.today().isoformat()}-report.md"
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)
    print("\n".join(lines))


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--limit", type=int)
    p.add_argument("--min-audio", type=float, default=30.0)
    p.add_argument("--model", default=backends.MLX_CLEANUP_DEFAULT)
    a = p.parse_args(argv)
    OUT.mkdir(parents=True, exist_ok=True, mode=0o700)
    con = sqlite3.connect(f"file:{HISTORY}?mode=ro", uri=True)
    rows = con.execute(
        "select id, audio_s, raw, coalesce(mode, 'casual'), backend from transcriptions "
        "where outcome = 'pasted' and raw is not null and audio_s >= ? order by id desc",
        (a.min_audio,),
    ).fetchall()[: a.limit]
    con.close()
    if not rows:
        raise SystemExit("No dictations to benchmark.")
    terms, _ = config.read_dictionary()
    engine = backends.MLXCleanup(a.model)
    engine.vocabulary = tuple(terms)
    engine.cleanup(rows[0][2][:600], rows[0][3])  # warm-up: compile kernels, build prefix

    results = []
    for n, (row_id, audio_s, raw, mode, backend) in enumerate(rows, 1):
        pieces = rebuild_pieces(raw, audio_s, backend)
        b_text, b_s, b_chunks = batch(engine, raw, mode)
        s = streaming(engine, raw, pieces, audio_s, mode)
        results.append({
            "id": row_id, "audio_s": audio_s, "words": len(raw.split()), "pieces": len(pieces),
            "batch_s": b_s, "batch_chunks": b_chunks,
            "stream_during_s": s["during_s"], "stream_after_s": s["after_s"], "stream_total_s": s["total_s"],
            "stream_chunks": s["chunks"], "early_words": s["early_words"],
            "identical": s["text"] == b_text,
            "similarity": difflib.SequenceMatcher(None, b_text.split(), s["text"].split()).ratio(),
            "load": os.getloadavg()[0],
            "batch_text": b_text, "stream_text": s["text"],
        })
        print(f"  {n}/{len(rows)} id {row_id}: batch {b_s:.2f}s, streaming wait "
              f"{s['after_s']:.2f}s", flush=True)

    path = OUT / "results.jsonl"
    path.write_text("".join(json.dumps(r) + "\n" for r in results))
    path.chmod(0o600)
    report(results, a.model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
