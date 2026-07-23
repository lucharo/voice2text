# Benchmarks

Two tables, models-as-columns, **median of N runs per cell**:

- **Speech-to-text** — transcription time and real-time factor (RTF = audio length ÷ processing time; higher is faster). Inputs are generated on the fly with macOS `say`, so the benchmark is self-contained.
- **Text cleanup** — time-to-first-token and total time for MLX or Ollama cleanup models.

Absolute numbers reflect the machine they ran on. **Compare models within a file, not across machines** — that's the point of one file per host.

## Run it

```bash
just bench                 # both tables, default models
just bench --cleanup       # cleanup only (default models use MLX)
just bench --cleanup --cleanup-models ollama:qwen3:4b-instruct-2507  # Ollama/Linux
just bench --stt           # STT only (needs Apple Silicon / MLX)
just bench --repeat 5      # more runs per cell
```

Override the model lists:

```bash
just bench --stt-models \
  parakeet:mlx-community/parakeet-tdt-0.6b-v3 \
  parakeet:mlx-community/parakeet-tdt-0.6b-v2 \
  whisper:mlx-community/whisper-large-v3-turbo

just bench --cleanup-models \
  mlx:mlx-community/Qwen2.5-1.5B-Instruct-4bit \
  mlx:mlx-community/Qwen3-4B-Instruct-2507-4bit \
  ollama:qwen3:4b-instruct-2507
```

Cleanup models are `engine:model` specs (`mlx:…` or `ollama:…`); a model that isn't
installed is marked `n/a` rather than aborting the run. Each run writes
`~/.v2t/benchmarks/results/<date>-<host>.md`; copy results into this directory when contributing
to the grid.

## Default models

| | model | notes |
|---|---|---|
| STT (default) | `mlx-community/parakeet-tdt-0.6b-v3` | multilingual (EN/ES/FR/DE…), fastest on Apple Silicon |
| STT (alt) | `mlx-community/parakeet-tdt-0.6b-v2` | English-only, slightly higher EN accuracy |
| STT (fallback) | `mlx-community/whisper-large-v3-turbo` | the old default; best for rare languages/accents |
| cleanup (default) | `mlx:mlx-community/Qwen2.5-1.5B-Instruct-4bit` | in-process, non-thinking; 831 MB active in the local benchmark |
| cleanup (quality alt) | `mlx:mlx-community/Qwen3-4B-Instruct-2507-4bit` | 4B previous default; higher memory |
| cleanup (ollama) | `ollama:qwen3:4b-instruct-2507` | if you already run Ollama |

> **Use a non-thinking model.** Hybrid Qwen3 tags emit `<think>…</think>` blocks that
> add latency and pollute the output; the `-instruct-2507` and Qwen2.5-Instruct
> models above don't think.

## Method

- Models loaded once, then each sample transcribed/cleaned `--repeat` times; the median is reported.
- STT inputs: short / medium / long clips synthesized with `say` and converted to 16 kHz mono with `afconvert` — no audio files to ship, fully reproducible.
- Cleanup inputs: three filler-laden raw transcriptions (see `v2t/bench.py`).
- TTFT comes from streaming generation (mlx-lm or the Ollama HTTP API) and timing the first token.

See `results/` for collected runs.
