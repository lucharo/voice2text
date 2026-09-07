# Wispr Flow benchmarking and profiling

Maintainer-only. Not part of the `voice2text` package, not in the wheel or sdist, no tests.
One question: **on the dictations I actually did, would v2t have been faster and no worse than
Wispr Flow?**

## Where the data is

Wispr Flow (macOS) keeps everything local in

```
~/Library/Application Support/Wispr Flow/flow.sqlite     # table: History
```

Useful columns: `asrText` (its raw ASR), `formattedText` (after its LLM pass), `editedText` (what
you left in the text box afterwards), `e2eLatency` (ms, stop-to-paste), `duration` /
`speechDuration` (s), `numWords`, `app`, `status`, `timestamp`, and from recent versions the
recorded `audio` (RIFF WAV) plus `opusChunks`. Older rows have no audio.

## Run

```bash
uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py --limit 20   # smoke
uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py              # every clip with audio
uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py --no-cleanup # Parakeet only
uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py --whisper    # third opinion, if cached
# one cell of a model × mode grid; --tag keeps results/report apart
uv run python utils/wisprflow_benchmarking_profiling/bench_wisprflow.py \
  --cleanup-model mlx-community/Qwen3.5-2B-4bit --mode casual --tag 2b-casual
# then compare tagged cells in one table
uv run python utils/wisprflow_benchmarking_profiling/compare_cells.py 08b-casual 15b-casual 2b-casual 4b-casual
```

Run cells one at a time (a shell loop, detached with `nohup`), never two models at once: they share
the GPU and contaminate each other's timings.

The DB is opened read-only. Everything the script writes goes to `~/.v2t/eval/wisprflow/`
(owner-only): `audio/<id>.wav`, `results[-<tag>].jsonl` (per clip: both transcripts, timings,
disagreement), and `<date>-report[-<tag>].md` (numbers and clip ids only, safe to share).

## Reading the report

- **Latency** is the solid part. Wispr's `e2eLatency` comes from its own table; v2t's is measured
  here on the same machine. Compare distributions, not means.
- **Disagreement is not error.** Wispr's transcripts are the comparator, not ground truth: they
  are sometimes cut short, sometimes rewritten. A high disagreement says "listen to this one".
- **Listening shortlist**: `afplay <wav>`, then read both texts from the `results[-<tag>].jsonl`
  the report names. Ten clips judged by ear tell you more than 200 numbers.
- `--whisper` adds `mlx-community/whisper-large-v3-turbo` as a third system when it is already in
  the Hugging Face cache (the script never downloads). Clips where Parakeet and Whisper agree and
  Wispr differs are the strongest evidence against Wispr; three-way splits are yours to judge.

## What it found so far (2026-09-04, M4 Pro, 208 clips, casual mode)

| cleanup model | words kept p50 / p10 | cleanup p50 | p90 | ms/word |
|---|--:|--:|--:|--:|
| Qwen3.5-0.8B-4bit | 96% / 86% | 0.61 s | 2.56 s | 6.3 |
| Qwen2.5-1.5B-Instruct-4bit | 92% / 82% | 0.85 s | 3.31 s | 8.3 |
| Qwen3.5-2B-4bit (default since) | 98% / 93% | 1.17 s | 4.76 s | 11.7 |
| Qwen3.5-4B-4bit | 96% / 90% | 2.21 s | 9.09 s | 22.8 |

Strict mode on the 1.5B kept 85% (39 clips under 75%) and on the 4B 86%; casual is the default for
that reason. Parakeet itself: ~11 ms per second of audio, median disagreement with Wispr's own ASR
13%. Wispr's median end-to-end latency over 1,275 dictations was 1.97 s (p90 4.3 s, p99 19.8 s).

## Not doing

No upload of anything, no writes to the Wispr DB, no transcript text in the report or in git.
