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
```

The DB is opened read-only. Everything the script writes goes to `~/.v2t/eval/wisprflow/`
(owner-only): `audio/<id>.wav`, `results.jsonl` (per clip: both transcripts, timings,
disagreement), and `<date>-report.md` (numbers and clip ids only, safe to share).

## Reading the report

- **Latency** is the solid part. Wispr's `e2eLatency` comes from its own table; v2t's is measured
  here on the same machine. Compare distributions, not means.
- **Disagreement is not error.** Wispr's transcripts are the comparator, not ground truth: they
  are sometimes cut short, sometimes rewritten. A high disagreement says "listen to this one".
- **Listening shortlist**: `afplay <wav>`, then read both texts from `results.jsonl`. Ten clips
  judged by ear tell you more than 200 numbers.
- `--whisper` adds `mlx-community/whisper-large-v3-turbo` as a third system when it is already in
  the Hugging Face cache (the script never downloads). Clips where Parakeet and Whisper agree and
  Wispr differs are the strongest evidence against Wispr; three-way splits are yours to judge.

## Not doing

No upload of anything, no writes to the Wispr DB, no transcript text in the report or in git.
