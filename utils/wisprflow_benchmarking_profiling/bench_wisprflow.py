"""Benchmark v2t against your own Wispr Flow history — same audio, local vs cloud.

Not user-facing and not packaged: a maintainer script for one question, "would
v2t have been faster and no worse on the dictations I actually did?"

Wispr Flow keeps every dictation in ~/Library/Application Support/Wispr Flow/flow.sqlite
(table `History`). Recent rows (from 2026-08 in Luis's DB) also keep the recorded
WAV, so the same audio can go through v2t. The DB is opened read-only; audio and
per-clip texts are written under ~/.v2t/eval/wisprflow (owner-only), and the
markdown report contains numbers and clip ids only, never transcript text.

    uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py            # all clips
    uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py --limit 20 # smoke run
    uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py --no-cleanup
    uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py --whisper  # 3rd opinion, if cached

Ground truth caveat: Wispr's `asrText` / `formattedText` are NOT truth — they
are the thing being compared. The report calls the metric *disagreement*, not
error. The listening shortlist at the end is where a human decides who was right.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import statistics
import sys
import time
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from v2t import backends  # noqa: E402  (repo import, after sys.path)

WISPR_DB = Path.home() / "Library/Application Support/Wispr Flow/flow.sqlite"
OUT_DIR = Path.home() / ".v2t/eval/wisprflow"
WHISPER_CACHE = (
    Path.home() / ".cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo"
)

_WORD = re.compile(r"[\w']+")


def words(text: str | None) -> list[str]:
    return _WORD.findall((text or "").lower())


def wer(reference: str | None, hypothesis: str | None) -> float:
    """Word-level edit distance / reference length. Symmetric enough for disagreement."""
    ref, hyp = words(reference), words(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        current = [i]
        for j, h in enumerate(hyp, 1):
            current.append(
                min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r != h))
            )
        previous = current
    return previous[-1] / len(ref)


def percentiles(values: list[float]) -> dict[str, float]:
    if not values:
        return {"n": 0}
    ordered = sorted(values)

    def q(p: float) -> float:
        return ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))]

    return {
        "n": len(values),
        "p50": q(0.5),
        "p90": q(0.9),
        "p99": q(0.99),
        "mean": statistics.fmean(values),
        "max": ordered[-1],
    }


def fmt_ms(value: float | None) -> str:
    return "–" if value is None else f"{value / 1000:.2f}s"


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


# --- Wispr Flow DB -----------------------------------------------------------


def connect(db: Path) -> sqlite3.Connection:
    if not db.exists():
        raise SystemExit(f"Wispr Flow database not found: {db}")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def db_profile(con: sqlite3.Connection) -> dict:
    """Latency profile of the whole history — the thing Luis actually feels."""
    rows = con.execute(
        "select e2eLatency, coalesce(speechDuration, duration) as d, numWords, "
        "substr(timestamp,1,7) as month, app, status from History "
        "where e2eLatency is not null and e2eLatency > 0"
    ).fetchall()
    total = con.execute("select count(*) from History").fetchone()[0]
    by_month: dict[str, list[float]] = {}
    by_bucket: dict[str, list[float]] = {"<15s": [], "15–60s": [], ">60s": []}
    per_second: dict[str, list[float]] = {"<15s": [], "15–60s": [], ">60s": []}
    for r in rows:
        by_month.setdefault(r["month"], []).append(r["e2eLatency"])
        d = r["d"] or 0
        bucket = "<15s" if d < 15 else "15–60s" if d < 60 else ">60s"
        by_bucket[bucket].append(r["e2eLatency"])
        if d:
            per_second[bucket].append(r["e2eLatency"] / d)
    return {
        "total_rows": total,
        "with_latency": len(rows),
        "overall": percentiles([r["e2eLatency"] for r in rows]),
        "by_month": {m: percentiles(v) for m, v in sorted(by_month.items())},
        "by_bucket": {b: percentiles(v) for b, v in by_bucket.items()},
        "ms_per_audio_second": {
            b: statistics.median(v) if v else None for b, v in per_second.items()
        },
    }


def export_clips(con: sqlite3.Connection, out: Path, limit: int | None) -> list[dict]:
    """Write each stored WAV once; return clip metadata (texts included, kept private)."""
    private_dir(out / "audio")
    query = (
        "select transcriptEntityId as id, timestamp, duration, speechDuration, "
        "e2eLatency, clientNetworkLatency, numWords, app, status, asrText, "
        "formattedText, editedText, usedFallbackAsr, audio from History "
        "where audio is not null and asrText is not null "
        "and status in ('formatted','raw_transcript') order by timestamp desc"
    )
    if limit:
        query += f" limit {int(limit)}"
    clips = []
    for r in con.execute(query):
        wav = out / "audio" / f"{r['id']}.wav"
        if not wav.exists():
            wav.write_bytes(r["audio"])
            wav.chmod(0o600)
        clips.append(
            {
                "id": r["id"],
                "timestamp": r["timestamp"],
                "duration_s": r["duration"],
                "speech_s": r["speechDuration"],
                "wispr_e2e_ms": r["e2eLatency"] or None,
                "wispr_network_ms": r["clientNetworkLatency"],
                "wispr_words": len(words(r["asrText"])),
                "app": r["app"],
                "status": r["status"],
                "wispr_asr": r["asrText"],
                "wispr_formatted": r["formattedText"],
                "wispr_edited": r["editedText"],
                "wispr_fallback_asr": bool(r["usedFallbackAsr"]),
                "wav": str(wav),
            }
        )
    return clips


# --- v2t -----------------------------------------------------------------------


def run_v2t(clips: list[dict], cleanup: bool, whisper: bool, mode: str) -> None:
    print(f"loading parakeet ({backends.PARAKEET_DEFAULT})…", flush=True)
    t0 = time.perf_counter()
    stt = backends.make_stt("parakeet")
    print(f"  {time.perf_counter() - t0:.1f}s", flush=True)
    cleaner = None
    if cleanup:
        print(f"loading cleanup ({backends.MLX_CLEANUP_DEFAULT})…", flush=True)
        t0 = time.perf_counter()
        cleaner = backends.make_cleanup("mlx")
        cleaner.cleanup("warm up", mode)
        print(f"  {time.perf_counter() - t0:.1f}s", flush=True)
    whisper_stt = None
    if whisper:
        if WHISPER_CACHE.exists():
            try:
                whisper_stt = backends.make_stt("whisper")
                print("whisper large-v3-turbo: cached, running as third opinion")
            except SystemExit as error:
                print(f"whisper skipped: {error}")
        else:
            print("whisper skipped: model not in the HF cache (no download here)")

    # warm the shapes once so the first clip is not paying compile time
    if clips:
        stt.transcribe(clips[0]["wav"])

    for index, clip in enumerate(clips, 1):
        t0 = time.perf_counter()
        raw = stt.transcribe(clip["wav"])
        clip["v2t_stt_ms"] = (time.perf_counter() - t0) * 1000
        clip["v2t_raw"] = raw
        clip["v2t_words"] = len(words(raw))
        clip["v2t_cleanup_ms"] = None
        clip["v2t_clean"] = None
        if cleaner is not None and raw:
            t0 = time.perf_counter()
            try:
                clean, _ttft, _total = cleaner.cleanup(raw, mode)
            except Exception as error:  # keep the row; note the failure
                clean = f"<cleanup failed: {error}>"
            clip["v2t_cleanup_ms"] = (time.perf_counter() - t0) * 1000
            clip["v2t_clean"] = clean
        clip["v2t_total_ms"] = clip["v2t_stt_ms"] + (clip["v2t_cleanup_ms"] or 0)
        if whisper_stt is not None:
            t0 = time.perf_counter()
            clip["whisper_raw"] = whisper_stt.transcribe(clip["wav"])
            clip["whisper_ms"] = (time.perf_counter() - t0) * 1000
        # Wispr "cut" a dictation when its formatted text keeps under half the
        # words of its own ASR — the truncations Luis complains about.
        fmt_words = len(words(clip["wispr_formatted"]))
        clip["wispr_cut"] = (
            clip["wispr_words"] > 0 and fmt_words < 0.5 * clip["wispr_words"]
        )
        # disagreement, not error: Wispr is the comparator, not the truth
        clip["dis_raw_vs_wispr_asr"] = wer(clip["wispr_asr"], raw)
        clip["dis_raw_vs_wispr_fmt"] = wer(clip["wispr_formatted"], raw)
        if clip["v2t_clean"]:
            clip["dis_clean_vs_wispr_fmt"] = wer(
                clip["wispr_formatted"], clip["v2t_clean"]
            )
        if whisper_stt is not None:
            clip["dis_raw_vs_whisper"] = wer(clip["whisper_raw"], raw)
            clip["dis_whisper_vs_wispr_asr"] = wer(
                clip["wispr_asr"], clip["whisper_raw"]
            )
        speed = (clip["duration_s"] or 0) / max(clip["v2t_total_ms"] / 1000, 1e-6)
        print(
            f"[{index}/{len(clips)}] {clip['duration_s'] or 0:5.1f}s audio  "
            f"v2t {clip['v2t_total_ms'] / 1000:5.2f}s ({speed:4.0f}×)  "
            f"wispr {fmt_ms(clip['wispr_e2e_ms']):>6}  "
            f"disagree {clip['dis_raw_vs_wispr_asr']:.2f}",
            flush=True,
        )


# --- report --------------------------------------------------------------------


def _row(label: str, p: dict) -> str:
    if not p.get("n"):
        return f"| {label} | 0 | – | – | – | – |"
    return (
        f"| {label} | {p['n']} | {fmt_ms(p['p50'])} | {fmt_ms(p['p90'])} | "
        f"{fmt_ms(p['p99'])} | {fmt_ms(p['mean'])} |"
    )


def report(profile: dict, clips: list[dict], cleanup: bool, whisper: bool) -> str:
    head = "| | n | p50 | p90 | p99 | mean |\n|---|--:|--:|--:|--:|--:|"
    lines = [
        f"# v2t vs Wispr Flow — {date.today()}",
        "",
        "_Same audio, your own dictations. Wispr numbers come from its local `History` table; "
        'v2t numbers are measured here. "Disagreement" is word-level edit distance between two '
        "transcripts — neither side is ground truth._",
        "",
        "## Wispr Flow latency, whole history",
        "",
        f"{profile['total_rows']} dictations, {profile['with_latency']} with an end-to-end latency recorded.",
        "",
        head,
        _row("all", profile["overall"]),
        *(_row(m, p) for m, p in profile["by_month"].items()),
        *(_row(f"audio {b}", p) for b, p in profile["by_bucket"].items()),
        "",
        "Median Wispr latency per second of audio: "
        + ", ".join(
            f"{b}: {v:.0f} ms/s" if v is not None else f"{b}: –"
            for b, v in profile["ms_per_audio_second"].items()
        )
        + ". A flat cost on short clips means fixed round-trip overhead, not model time.",
        "",
        "## Same clips, v2t vs Wispr",
        "",
    ]
    with_lat = [c for c in clips if c["wispr_e2e_ms"]]
    lines += [
        f"{len(clips)} clips with stored audio ({sum(c['duration_s'] or 0 for c in clips) / 60:.0f} min); "
        f"{len(with_lat)} of them also carry a Wispr latency.",
        "",
        head,
        _row(
            "Wispr end-to-end (those clips)",
            percentiles([c["wispr_e2e_ms"] for c in with_lat]),
        ),
        _row("v2t Parakeet only", percentiles([c["v2t_stt_ms"] for c in clips])),
    ]
    if cleanup:
        lines.append(
            _row(
                "v2t Parakeet + cleanup",
                percentiles([c["v2t_total_ms"] for c in clips]),
            )
        )
    if whisper and any("whisper_ms" in c for c in clips):
        lines.append(
            _row(
                "Whisper large-v3-turbo",
                percentiles([c["whisper_ms"] for c in clips if "whisper_ms" in c]),
            )
        )
    if with_lat:
        ratio = statistics.median(
            c["wispr_e2e_ms"] / c["v2t_total_ms"] for c in with_lat
        )
        lines += [
            "",
            f"Median speed-up on the clips with both numbers: **{ratio:.0f}×**.",
        ]
    lines += [
        "",
        "## Disagreement with Wispr",
        "",
        "| comparison | median | p90 | clips over 0.25 |",
        "|---|--:|--:|--:|",
    ]

    cut = [c for c in clips if c.get("wispr_cut")]
    intact = [c for c in clips if not c.get("wispr_cut")]

    def dis_row(label: str, key: str, subset: list[dict] | None = None) -> str:
        values = [c[key] for c in (subset if subset is not None else clips) if key in c]
        if not values:
            return f"| {label} | – | – | – |"
        p = percentiles(values)
        return f"| {label} | {p['p50']:.3f} | {p['p90']:.3f} | {sum(v > 0.25 for v in values)} |"

    lines += [
        dis_row("v2t raw vs Wispr ASR", "dis_raw_vs_wispr_asr"),
        dis_row(
            "v2t raw vs Wispr formatted (cut clips excluded)",
            "dis_raw_vs_wispr_fmt",
            intact,
        ),
    ]
    if cleanup:
        lines.append(
            dis_row(
                "v2t clean vs Wispr formatted (cut clips excluded)",
                "dis_clean_vs_wispr_fmt",
                intact,
            )
        )
    lines += [
        "",
        f"**Wispr cut the dictation in {len(cut)} of {len(clips)} clips**: its formatted text kept "
        "under half the words of its own ASR. Those are excluded from the formatted comparisons "
        "above; v2t's raw transcript is the full recording in every case.",
    ]
    if whisper and any("dis_raw_vs_whisper" in c for c in clips):
        lines += [
            dis_row("v2t raw vs Whisper", "dis_raw_vs_whisper"),
            dis_row("Whisper vs Wispr ASR", "dis_whisper_vs_wispr_asr"),
        ]
    worst = sorted(clips, key=lambda c: c["dis_raw_vs_wispr_asr"], reverse=True)[:10]
    lines += [
        "",
        "## Listening shortlist",
        "",
        "The ten clips where Parakeet and Wispr disagree most. Play one with "
        "`afplay <wav>` and read both transcripts from `results.jsonl` to decide who was right.",
        "",
        "| clip | audio | words wispr/v2t | disagreement | wispr cut? | wav |",
        "|---|--:|--:|--:|:-:|---|",
        *(
            f"| {c['id'][:8]} | {c['duration_s'] or 0:.0f}s | {c['wispr_words']}/{c['v2t_words']} "
            f"| {c['dis_raw_vs_wispr_asr']:.2f} | {'yes' if c.get('wispr_cut') else ''} | `{c['wav']}` |"
            for c in worst
        ),
        "",
        "_Per-clip texts and timings: `results.jsonl` next to this report (owner-only)._",
    ]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--db", type=Path, default=WISPR_DB)
    p.add_argument("--out", type=Path, default=OUT_DIR)
    p.add_argument("--limit", type=int, help="newest N clips only (smoke run)")
    p.add_argument("--no-cleanup", action="store_true", help="Parakeet only")
    p.add_argument("--mode", choices=["strict", "casual"], default="strict")
    p.add_argument("--whisper", action="store_true", help="add Whisper turbo if cached")
    a = p.parse_args(argv)

    out = private_dir(a.out.expanduser())
    con = connect(a.db.expanduser())
    profile = db_profile(con)
    clips = export_clips(con, out, a.limit)
    con.close()
    if not clips:
        raise SystemExit("no Wispr Flow rows with stored audio")
    print(f"{len(clips)} clips exported to {out / 'audio'}")

    run_v2t(clips, cleanup=not a.no_cleanup, whisper=a.whisper, mode=a.mode)

    results = out / "results.jsonl"
    with open(os.open(results, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        for clip in clips:
            f.write(json.dumps(clip, ensure_ascii=False) + "\n")
    text = report(profile, clips, cleanup=not a.no_cleanup, whisper=a.whisper)
    report_path = out / f"{date.today()}-report.md"
    report_path.write_text(text)
    report_path.chmod(0o600)
    print(f"\nwrote {report_path}\n")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
