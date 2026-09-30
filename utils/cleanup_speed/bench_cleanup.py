"""How fast can the local cleanup pass get without changing its output?

Maintainer-only, not packaged. Runs v2t's MLX cleanup over the raw Parakeet transcripts of
the Wispr bench clips (``~/.v2t/eval/wisprflow/results-2b-casual.jsonl``, field ``v2t_raw``)
three ways, all greedy, so every variant must return the baseline's exact text:

- ``baseline``: ``MLXCleanup.cleanup`` as shipped (every call prefills the whole prompt).
- ``prefix``: the system prompt, the worked examples and the dictionary are the same for
  every call; prefill them once, keep the cache, and feed only the dictation.
- ``lookup``: ``prefix`` plus prompt-lookup decoding. Cleaned text mostly copies the
  dictation, so the next few tokens are guessed from the dictation where the last few
  output tokens match it, and one forward pass checks them all.

It also reports, from the baseline's own per-chunk times, the wait left after release if
every chunk but the last were cleaned while the dictation was still being recorded.

    .venv/bin/python utils/cleanup_speed/bench_cleanup.py --limit 20     # smoke
    .venv/bin/python utils/cleanup_speed/bench_cleanup.py                # all clips

Writes ``~/.v2t/eval/cleanup-speed/<date>-report.md`` (numbers only) and a private
per-clip ``results.jsonl``. Run it alone on the GPU; anything else sharing it skews times.
"""

from __future__ import annotations

import argparse
import copy
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

import mlx.core as mx  # noqa: E402

from v2t import backends, config  # noqa: E402

SOURCE = Path.home() / ".v2t/eval/wisprflow/results-2b-casual.jsonl"
OUT = Path.home() / ".v2t/eval/cleanup-speed"
MODE = "casual"


class FastCleanup(backends.MLXCleanup):
    """MLXCleanup with a reused prefix cache and, optionally, prompt-lookup decoding.

    Qwen3.5 mixes linear-attention layers (a recurrent state, ``ArraysCache``) with
    full-attention ones (``KVCache``). A recurrent state cannot be trimmed back, so
    both tricks work from snapshots: the prefix cache is deep-copied per call, and a
    lookup draft that is only partly accepted restores the pre-draft snapshot and
    re-feeds the accepted tokens.
    """

    def __init__(
        self, model: str = "", lookup: bool = False, draft: int = 8, ngram: int = 3
    ):
        super().__init__(model)
        from mlx_lm.models import cache

        self._cache_mod = cache
        self.lookup, self.draft, self.ngram = lookup, draft, ngram
        self._prefix_key = None
        self._prefix_tokens: list[int] = []
        self._prefix_cache = None
        self.eos = set(self.tokenizer.eos_token_ids)

    def _tokens(self, chunk: str, mode: str) -> list[int]:
        prompt = self.tokenizer.apply_chat_template(
            self._messages(chunk, mode),
            add_generation_prompt=True,
            enable_thinking=False,
        )
        return (
            list(prompt)
            if not isinstance(prompt, str)
            else self.tokenizer.encode(prompt)
        )

    def _prefix(self, mode: str) -> tuple[list[int], list]:
        """Tokens shared by every call in this mode (and dictionary), and their cache."""
        key = (mode, tuple(self.vocabulary))
        if key != self._prefix_key:
            a, b = self._tokens("alpha one", mode), self._tokens("beta two three", mode)
            n = 0
            while n < min(len(a), len(b)) and a[n] == b[n]:
                n += 1
            prefix = a[:n]
            prompt_cache = self._cache_mod.make_prompt_cache(self.model)
            self.model(mx.array(prefix)[None], cache=prompt_cache)
            mx.eval([c.state for c in prompt_cache])
            self._prefix_key, self._prefix_tokens, self._prefix_cache = (
                key,
                prefix,
                prompt_cache,
            )
        return self._prefix_tokens, self._prefix_cache

    def _generate(self, chunk: str, mode: str):
        tokens = self._tokens(chunk, mode)
        prefix, prefix_cache = self._prefix(mode)
        assert tokens[: len(prefix)] == prefix, (
            "prompt no longer starts with the cached prefix"
        )
        suffix = tokens[len(prefix) :]
        prompt_cache = copy.deepcopy(prefix_cache)
        max_tokens = int(len(self.tokenizer.encode(chunk)) * 1.5) + 64
        t0 = time.perf_counter()
        logits = self.model(mx.array(suffix)[None], cache=prompt_cache)
        nxt = int(mx.argmax(logits[0, -1]).item())
        ttft = time.perf_counter() - t0
        source = self.tokenizer.encode(chunk)
        out: list[int] = []
        self.accepted = getattr(self, "accepted", 0)
        while nxt not in self.eos and len(out) < max_tokens:
            out.append(nxt)
            guess = self._guess(out, source) if self.lookup else []
            if not guess:
                logits = self.model(mx.array([nxt])[None], cache=prompt_cache)
                nxt = int(mx.argmax(logits[0, -1]).item())
                continue
            snapshot = [
                copy.deepcopy(c) if not c.is_trimmable() else None for c in prompt_cache
            ]
            fed = [nxt] + guess
            logits = self.model(mx.array(fed)[None], cache=prompt_cache)
            picks = mx.argmax(logits[0], axis=-1).tolist()
            ok = 0
            while (
                ok < len(guess) and picks[ok] == guess[ok] and guess[ok] not in self.eos
            ):
                ok += 1
            out.extend(guess[:ok])
            self.accepted += ok
            if ok < len(
                guess
            ):  # roll back to before the draft, re-feed what was accepted
                for i, c in enumerate(prompt_cache):
                    if snapshot[i] is None:
                        c.trim(len(fed))
                    else:
                        prompt_cache[i] = snapshot[i]
                self.model(mx.array(fed[: 1 + ok])[None], cache=prompt_cache)
            nxt = picks[ok]
        text = self.tokenizer.decode(out)
        return text, ttft, len(out) >= max_tokens

    def _guess(self, out: list[int], source: list[int]) -> list[int]:
        """The source tokens that followed the latest earlier match of the output's tail."""
        tail = out[-self.ngram :]
        if len(tail) < self.ngram:
            return []
        for start in range(len(source) - self.ngram, -1, -1):
            if source[start : start + self.ngram] == tail:
                return source[start + self.ngram : start + self.ngram + self.draft]
        return []


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
        "baseline": backends.MLXCleanup(a.model),
        "prefix": FastCleanup(a.model),
        "lookup": FastCleanup(a.model, lookup=True),
    }
    for engine in engines.values():
        engine.vocabulary = tuple(terms)
        timed_chunks(
            engine, clips[0]["v2t_raw"]
        )  # warm-up: compile kernels, build prefix
    engines["lookup"].accepted = 0

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
    out_tokens = sum(
        len(engines["lookup"].tokenizer.encode(r["lookup_text"])) for r in results
    )
    lines.append(
        f"Lookup accepted {engines['lookup'].accepted} guessed tokens of ~{out_tokens} output tokens."
    )
    report = OUT / f"{date.today().isoformat()}-report.md"
    report.write_text("\n".join(lines) + "\n")
    report.chmod(0o600)
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
