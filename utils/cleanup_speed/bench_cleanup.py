"""How fast can the local cleanup pass get without changing its output?

Maintainer-only, not packaged. Runs the cleanup over the raw Parakeet transcripts of the
Wispr bench clips (``~/.v2t/eval/wisprflow/results-2b-casual.jsonl``, field ``v2t_raw``) three
ways, all greedy:

- ``baseline``: the cleanup as it was before the speed-up, mlx-lm's ``stream_generate`` over the
  whole prompt on every call.
- ``prefix``: v2t's ``MLXCleanup`` with prompt lookup off: the system prompt, worked examples and
  dictionary are prefilled once and their cache copied per call.
- ``lookup``: v2t's ``MLXCleanup`` as shipped: the prefix cache plus prompt-lookup decoding, which
  guesses the next tokens from the dictation and checks them in one forward pass.

Prefilling in two parts and checking several tokens per pass change float rounding, so a few
near-tie tokens can differ from the baseline; the report counts identical texts. It also
reports the wait left after release if every chunk but the last were cleaned while recording.

    .venv/bin/python utils/cleanup_speed/bench_cleanup.py --limit 20     # smoke
    .venv/bin/python utils/cleanup_speed/bench_cleanup.py                # all clips

Writes ``~/.v2t/eval/cleanup-speed/<date>-report.md`` (numbers only) and a private
per-clip ``results.jsonl``. Run it alone on the GPU; anything else sharing it skews times.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from datetime import date
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))


from v2t import backends, config  # noqa: E402

SOURCE = Path.home() / ".v2t/eval/wisprflow/results-2b-casual.jsonl"
OUT = Path.home() / ".v2t/eval/cleanup-speed"
MODE = "casual"


class StreamCleanup(backends.MLXCleanup):
    """The cleanup v2t shipped before the speed-up: mlx-lm's stream_generate over
    the whole prompt on every call, one token per model step."""

    def _generate(self, chunk: str, mode: str):
        from mlx_lm import stream_generate

        prompt = self._prompt(chunk, mode)
        max_tokens = int(len(self.tokenizer.encode(chunk)) * 1.5) + 64
        t0, ttft, parts = time.perf_counter(), None, []
        for resp in stream_generate(
            self.model, self.tokenizer, prompt, max_tokens=max_tokens
        ):
            if ttft is None:
                ttft = time.perf_counter() - t0
            parts.append(resp.text)
        return "".join(parts), ttft, len(parts) >= max_tokens


class PrefixOnlyCleanup(backends.MLXCleanup):
    """The shipped cleanup with prompt lookup turned off: only the prefix cache."""

    def _decode(self, prompt, mode, source, max_tokens):
        t0 = time.perf_counter()
        decoder = backends._MLXDecoder(self.model, *self._prefix(mode), list(prompt))
        ttft = time.perf_counter() - t0
        eos = set(self.tokenizer.eos_token_ids)
        return backends.lookup_decode(decoder, source, eos, max_tokens, draft=0), ttft


def q(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))]


def timed_chunks(engine, text: str) -> tuple[str, list[float]]:
    """Clean like ``cleanup`` does, keeping each chunk's own time."""
    parts, times = [], []
    for chunk in backends.chunk_text(text):
        t0 = time.perf_counter()
        clean, _, limited = engine._generate(chunk, MODE)
        times.append(time.perf_counter() - t0)
        clean = clean.strip()
        if limited or not clean or not backends.within_length_guard(chunk, clean, MODE):
            clean = chunk
        parts.append(clean)
    return " ".join(parts).strip(), times


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--limit", type=int)
    p.add_argument("--model", default=backends.MLX_CLEANUP_DEFAULT)
    a = p.parse_args(argv)
    OUT.mkdir(parents=True, exist_ok=True, mode=0o700)
    rows = [json.loads(line) for line in SOURCE.read_text().splitlines() if line]
    clips = [r for r in rows if (r.get("v2t_raw") or "").strip()][: a.limit]
    terms, _ = config.read_dictionary()

    engines = {
        "baseline": StreamCleanup(a.model),
        "prefix": PrefixOnlyCleanup(a.model),
        "lookup": backends.MLXCleanup(a.model),
    }
    for engine in engines.values():
        engine.vocabulary = tuple(terms)
        timed_chunks(
            engine, clips[0]["v2t_raw"]
        )  # warm-up: compile kernels, build prefix

    results = []
    for n, clip in enumerate(clips, 1):
        row = {"id": clip["id"], "duration_s": clip["duration_s"]}
        for name, engine in engines.items():
            text, times = timed_chunks(engine, clip["v2t_raw"])
            row[f"{name}_s"] = sum(times)
            row[f"{name}_last_chunk_s"] = times[-1] if times else 0.0
            row[f"{name}_chunks"] = len(times)
            row[f"{name}_text"] = text
        row["prefix_same"] = row["prefix_text"] == row["baseline_text"]
        row["lookup_same"] = row["lookup_text"] == row["baseline_text"]
        results.append(row)
        if n % 10 == 0 or n == len(clips):
            print(f"  {n}/{len(clips)}", flush=True)

    path = OUT / "results.jsonl"
    path.write_text("".join(json.dumps(r) + "\n" for r in results))
    path.chmod(0o600)

    lines = [
        f"# Cleanup speed, {date.today().isoformat()}",
        "",
        f"{len(results)} clips, {a.model}, {MODE} mode, {len(terms)} dictionary terms. "
        "Seconds of cleanup per dictation (all chunks).",
        "",
        "| variant | p50 | p90 | mean | identical to baseline |",
        "|---|--:|--:|--:|--:|",
    ]
    for name in engines:
        v = [r[f"{name}_s"] for r in results]
        same = (
            "–"
            if name == "baseline"
            else f"{sum(r[f'{name}_same'] for r in results)}/{len(results)}"
        )
        lines.append(
            f"| {name} | {q(v, 0.5):.2f} | {q(v, 0.9):.2f} | {statistics.fmean(v):.2f} | {same} |"
        )
    for name in engines:
        v = [r[f"{name}_last_chunk_s"] for r in results]
        lines.append(
            f"| {name}, cleaned while recording (only the last chunk after release) "
            f"| {q(v, 0.5):.2f} | {q(v, 0.9):.2f} | {statistics.fmean(v):.2f} | |"
        )
    multi = sum(r["baseline_chunks"] > 1 for r in results)
    lines += ["", f"{multi} of {len(results)} dictations have more than one chunk."]
    lines.append()
    report = OUT / f"{date.today().isoformat()}-report.md"
    report.write_text("\n".join(lines) + "\n")
    report.chmod(0o600)
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
