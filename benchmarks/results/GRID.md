# Cross-machine grid

The rollup view: rows = machines, columns = models. Fill each cell by running
`v2t bench` on that machine (it also writes a detailed `<date>-<host>.md` here).
Compare a column down the rows to see how a model scales with hardware.

## Speech-to-text — transcription time on the medium clip (RTF)

_Lower time / higher RTF is better. Needs Apple Silicon (MLX)._

| machine | parakeet-tdt-0.6b-v3 | parakeet-tdt-0.6b-v2 | whisper-large-v3-turbo |
|---|--:|--:|--:|
| Linux x86 (remote container) | n/a — no MLX | n/a — no MLX | n/a — no MLX |
| MacBook (personal) — M1 Pro | 0.29s (36×) | 0.27s (40×) | 1.61s (7×) |
| MacBook (work) | _todo_ | _todo_ | _todo_ |

## Text cleanup — TTFT / total on the median sample

_Lower is better. mlx engine needs Apple Silicon; ollama engine needs Ollama._

| machine | mlx:Qwen3-4B-Instruct-2507-4bit | mlx:Qwen2.5-3B-Instruct-4bit | ollama:qwen3:4b-instruct-2507 |
|---|--:|--:|--:|
| Linux x86 (remote container) | n/a — no MLX | n/a — no MLX | _todo¹_ |
| MacBook (personal) — M1 Pro | 0.55 / 0.97s | 0.30 / 0.51s | _not run_ |
| MacBook (work) | _todo_ | _todo_ | _todo_ |

¹ The default cleanup (mlx-lm) needs Apple Silicon. The remote Linux box can only
run the `ollama:` column, and only once Ollama is installed — CPU x86 timings
aren't representative of a Mac, so treat that cell as a sanity check, not a target.

_Detailed per-run numbers: [`2026-06-16-Apple-M1-Pro.md`](2026-06-16-Apple-M1-Pro.md)._

## Transcript quality (accuracy)

Speed ≠ accuracy. The benchmark clips are macOS `say` (synthetic, clean), so all
three STT models score ~0–2% WER on them locally — a sanity check (they transcribe
correctly and punctuate/capitalise well), too easy to separate models.

For real-world accuracy, trust the [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard),
which computes WER across 8 datasets with proper normalisation (more rigorous than
a quick local run):

| model | English avg WER | notes |
|---|--:|---|
| parakeet-tdt-0.6b-v2 | ~6.0% | English-only; topped the leaderboard |
| **parakeet-tdt-0.6b-v3** (default) | ~6.3% | multilingual; small English cost vs v2 |
| whisper-large-v3-turbo | ~7.5–8% | distilled large-v3, trades accuracy for speed |

So the default (**Parakeet v3**) is ~6.3% WER *and* the fastest here — the right
call. Switch to v2 (`model = "mlx-community/parakeet-tdt-0.6b-v2"`) for a hair more
English accuracy if you never need other languages. Cleanup can't recover missing
words, so STT WER is the accuracy that matters; punctuation/casing it fixes anyway.

---

**How to fill this in**

```bash
# on each Mac:
v2t bench                       # both tables -> benchmarks/results/<date>-<host>.md
# on a Linux box with Ollama:
v2t bench --cleanup             # cleanup table only
```

Then copy the medium-clip / median-sample numbers from each per-host file into
the rows above.
