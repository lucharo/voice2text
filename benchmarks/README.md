# Benchmarks

Two tables, models-as-columns, **median of N runs per cell**:

- **Speech-to-text** — transcription time and real-time factor (RTF = audio length ÷ processing time; higher is faster). Inputs are generated on the fly with macOS `say`, so the benchmark is self-contained.
- **Text cleanup** — time-to-first-token and total time for the Ollama cleanup model.

Absolute numbers reflect the machine they ran on. **Compare models within a file, not across machines** — that's the point of one file per host.

## Run it

```bash
v2t bench                 # both tables, default models
v2t bench --cleanup       # cleanup only (runs anywhere Ollama runs — no Apple Silicon needed)
v2t bench --stt           # STT only (needs Apple Silicon / MLX)
v2t bench --repeat 5      # more runs per cell
```

Override the model lists:

```bash
v2t bench --stt-models \
  parakeet:mlx-community/parakeet-tdt-0.6b-v3 \
  parakeet:mlx-community/parakeet-tdt-0.6b-v2 \
  whisper:mlx-community/whisper-large-v3-turbo

v2t bench --cleanup-models qwen3:4b-instruct-2507 qwen3:1.7b qwen2.5:3b
```

Each run writes `results/<date>-<host>.md`. Commit it. Run on each Mac (and the
Linux box, for the cleanup table) to build the grid.

## Default models

| | model | notes |
|---|---|---|
| STT (default) | `mlx-community/parakeet-tdt-0.6b-v3` | multilingual (EN/ES/FR/DE…), fastest on Apple Silicon |
| STT (alt) | `mlx-community/parakeet-tdt-0.6b-v2` | English-only, slightly higher EN accuracy |
| STT (fallback) | `mlx-community/whisper-large-v3-turbo` | the old default; best for rare languages/accents |
| cleanup (default) | `qwen3:4b-instruct-2507` | latest small instruct, **non-thinking** |
| cleanup (alt) | `qwen3:1.7b` | smaller/faster |
| cleanup (old) | `qwen2.5:3b` | the previous default |

> **Why the `-instruct-2507` Qwen3 and not plain `qwen3`?** The plain tags default
> to hybrid *thinking* mode and emit `<think>…</think>` blocks, which add latency
> and pollute the output. The `-instruct` variants don't think. (v2t also strips
> any stray `<think>` blocks defensively.)

## Method

- Models loaded once, then each sample transcribed/cleaned `--repeat` times; the median is reported.
- STT inputs: short / medium / long clips synthesized with `say` and converted to 16 kHz mono with `afconvert` — no audio files to ship, fully reproducible.
- Cleanup inputs: three filler-laden raw transcriptions (see `v2t/bench.py`).
- TTFT comes from streaming the Ollama HTTP API and timing the first token.

See `results/` for collected runs.
