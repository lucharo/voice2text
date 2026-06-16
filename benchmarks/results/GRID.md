# Cross-machine grid

The rollup view: rows = machines, columns = models. Fill each cell by running
`v2t bench` on that machine (it also writes a detailed `<date>-<host>.md` here).
Compare a column down the rows to see how a model scales with hardware.

## Speech-to-text — transcription time on the medium clip (RTF)

_Lower time / higher RTF is better. Needs Apple Silicon (MLX)._

| machine | parakeet-tdt-0.6b-v3 | parakeet-tdt-0.6b-v2 | whisper-large-v3-turbo |
|---|--:|--:|--:|
| Linux x86 (remote container) | n/a — no MLX | n/a — no MLX | n/a — no MLX |
| MacBook (personal) | _todo_ | _todo_ | _todo_ |
| MacBook (work) | _todo_ | _todo_ | _todo_ |

## Text cleanup — TTFT / total on the median sample

_Lower is better. Needs Ollama._

| machine | qwen3:4b-instruct-2507 | qwen3:1.7b | qwen2.5:3b |
|---|--:|--:|--:|
| Linux x86 (remote container) | _todo¹_ | _todo¹_ | _todo¹_ |
| MacBook (personal) | _todo_ | _todo_ | _todo_ |
| MacBook (work) | _todo_ | _todo_ | _todo_ |

¹ The remote container can run the cleanup table once Ollama is installed
(`v2t bench --cleanup`), but CPU x86 timings are not representative of a Mac —
treat that row as a sanity check, not a target.

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
