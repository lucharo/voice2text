# ASR model grid

Maintainer-only. Not part of the `voice2text` package, not in the wheel or sdist. One question:
**is there a speech-to-text model, natively streaming or just newer, that beats Parakeet v3 for
dictation on this Mac?**

## Systems

| name | runtime | what it is |
|---|---|---|
| `parakeet-v3` | parakeet-mlx | v2t up to 0.5.7: whole-file under 60 s, the local-attention stream from 60 s up. Since 0.5.8 v2t ships `parakeet-v3+chunked` (below) |
| `parakeet-ultra` | parakeet-mlx | Moondream's v3 fine-tune (Sept 2026), same architecture, run as a drop-in for v3 (same 60 s rule). The grid uses `selcukkubur/parakeet-ultra-mlx`; `beshkenadze/parakeet-ultra-mlx-fp16` is the other MLX conversion (October 2026) |
| `parakeet-v3-coreml` | coremltools | v2t's opt-in `parakeet-coreml` decode: FluidAudio's Parakeet v3 Core ML files on the Neural Engine, whole-file. Needs `coremltools` in the environment (`uv sync --extra coreml`) and the files in FluidAudio's cache |
| `whisper-turbo` | mlx-whisper | v2t's alternative backend |
| `nemotron-3.5-stream` | mlx-audio | cache-aware streaming Nemotron 3.5, multilingual |
| `voxtral-rt-4bit` | mlx-audio | Mistral Voxtral Mini 4B Realtime, natively streaming, 4-bit |
| `qwen3-asr-1.7b` (and `-8bit`) | mlx-audio | best open model on the 2026 Open ASR Leaderboard, offline |
| `cohere-transcribe` | mlx-audio | Cohere Transcribe 03-2026, 2B, Apache-2.0, offline, told each clip's language (it has no language detection). Full precision from `viethang/cohere-transcribe-03-2026`, an ungated mirror of the gated `CohereLabs` checkpoint, because mlx-audio reads that layout; the MLX conversions on the Hub (`beshkenadze/*`, `mlx-community/*`) use mlx-audio-swift or mlx-speech tensor names and come out as noise (2026-10-14) |
| `parakeet-redux` | mlx-audio | Moondream's ternary (1.58-bit) Parakeet v3, 178 MB, offline. Phone candidate |
| `phonon-2` (and `-packed`) | fermion-research | Fermion's Parakeet v3 retrained at ~2.1 bits, 164 MB, English only, through its own MLX engine (on mlx-audio's Parakeet graph) in an env of its own. `phonon-2` is the engine's default, which dequantises the encoder to fp16; `-packed` keeps it packed (`FERMION_P2_FAST=tdt16`), the memory a phone would need. Phone candidate |
| `parakeet-unified-en` | parakeet-mlx | NVIDIA's English Parakeet Unified, offline mode only: `littlebearlabs/parakeet-unified-en-0.6b-mlx` (fp32, NeMo layout) mapped onto stock parakeet-mlx by `grid.load_nemo_layout` and cast to bf16 like every parakeet-mlx row. Its streaming mode is not run |

Each cell from 2026-10-14 also records MLX's peak memory per clip (weights included), the
report's `peak` column.

Not in the grid, because no MLX runtime runs them faithfully today (2026-09-29):

- `nvidia/nemotron-speech-streaming-en-0.6b` via `nemotron-asr-mlx` 0.2.0: its streaming path
  lacks the pre-encode cache and dropped words (45% WER streamed against 20% whole-file on the
  same 28 s LibriSpeech clip). mlx-audio's Nemotron session expects the multilingual prompt layer,
  so `nemotron-3.5-stream` is the cache-aware candidate.

## Clip sets

`ls-clean`, `ls-other` (LibriSpeech test, openslr.org), `fleurs-es` (FLEURS es_419 test): 150
labelled clips each, seeded, scored as WER after Whisper's text normalisation. `wispr`: the 208
dictations exported by `../wisprflow_benchmarking_profiling`, which have no ground truth; each
system is scored against the consensus (medoid) of the other systems, its own model family left out, plus Wispr's
own ASR. That measures agreement, not correctness.

## Run

Each runtime lives in its own environment so their pins never meet v2t's lock:

```bash
uv venv ~/.v2t/eval/grid-envs/mlxaudio && VIRTUAL_ENV=~/.v2t/eval/grid-envs/mlxaudio \
  uv pip install mlx-audio==0.5.7 soundfile whisper-normalizer
VIRTUAL_ENV=~/.v2t/eval/grid-envs/mlxaudio uv pip install sentencepiece  # Cohere's tokenizer
VIRTUAL_ENV=.venv uv pip install whisper-normalizer rapidfuzz pyyaml  # Parakeet and Whisper run in v2t's own venv
uv venv ~/.v2t/eval/grid-envs/phonon && VIRTUAL_ENV=~/.v2t/eval/grid-envs/phonon \
  uv pip install 'fermion-research[mlx]==0.2.11' soundfile whisper-normalizer rapidfuzz

~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py prepare
.venv/bin/python utils/asr_grid/grid.py run --system parakeet-v3 --set ls-clean
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py run --system voxtral-rt-4bit --set wispr
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py chunk --system qwen3-asr-1.7b-8bit --set wispr
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py report
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/report_html.py --headline "..."
.venv/bin/python utils/asr_grid/plot_wait.py               # the README's wait-vs-length chart
uv run --script utils/asr_grid/plot_pareto.py              # WER vs size and vs wait, short sets
```

Run cells one at a time: two models on the GPU contaminate each other's timings. Check `df -h /`
and swap first: at 595 MB free a cell died with no traceback, and swapping inflated the waits of
another, so rerun a spoiled cell rather than keep it. Results from before 2026-10-06 on long sets
swapped by themselves: the harness kept MLX's buffer cache, about 3.5 GB per ls-long clip, and now
clears it after every clip. Voxtral's realtime session can end itself
early and return no words; `stopped_early_s` records where. Cells resume where they stopped. Models load offline from the Hugging Face cache; where huggingface.co is
blocked, download them elsewhere (`hf download <repo>` with `HF_HUB_CACHE` pointed at a folder)
and rsync that folder into `~/.cache/huggingface/hub`.

Everything is written under `~/.v2t/eval/grid` (owner-only): manifests, per-clip results with
transcripts, and `<date>-report.md`, which holds numbers only.

For every finished cell on one screen (WER against wait and against disk, our numbers against
the Open ASR Leaderboard's, which engine runs which model), run `just intake`: the notebook in
[`../model_intake`](../model_intake/intake.py) scores these results with `score_set` and reads its
model facts from [`models.toml`](../model_intake/models.toml), where a new model is onboarded.

## Reading the numbers

- **Wait** is seconds from release to the final text: the whole-file decode for an offline
  system, the last push plus flush for a streaming one (everything earlier was fed and decoded
  while "recording"). For `parakeet-v3` it follows v2t's 60 s rule as it was up to 0.5.7.
- **`<system>+chunked`** gives a whole-file system the same 60 s rule. Under 60 s it is the
  whole-file run. From 60 s up, the recording is cut every ~30 s at the quietest 100 ms within 5 s
  of the mark (the splitter mlx-audio's Qwen3-ASR uses for long files), each piece is decoded as
  soon as its cut is known, and only the last piece is left after release. The wait counts any
  piece still queued at release. `grid.py chunk` writes these to `<system>.chunked.jsonl` beside
  the whole-file results; a chunked row is scored but never votes in the dictation consensus, so
  adding one moves no other number. `parakeet-v3+chunked` is what v2t ships since 0.5.8: the app's
  `PieceDecoder` cuts the same way, and gave the same text on the clips checked.
- **RTF** is compute over audio. A streaming system needs it well under 1 to keep up live.
- Streaming sessions are fed 0.5 s at a time and drained between feeds; the drain for mlx-audio
  sessions reads their queue state, which is pinned to mlx-audio 0.5.7.

What the grid found for long dictations, Parakeet in 30 s pieces against today's stream, is in
[internal/streaming.md](../../internal/streaming.md#would-30-s-pieces-beat-the-5-s-stream-for-long-dictations).
