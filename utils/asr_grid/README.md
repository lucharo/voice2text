# ASR model grid

Maintainer-only. Not part of the `voice2text` package, not in the wheel or sdist. One question:
**is there a speech-to-text model, natively streaming or just newer, that beats Parakeet v3 for
dictation on this Mac?**

## Systems

| name | runtime | what it is |
|---|---|---|
| `parakeet-v3` | parakeet-mlx | v2t today: whole-file under 60 s, the local-attention stream from 60 s up |
| `parakeet-ultra` | parakeet-mlx | Moondream's v3 fine-tune (Sept 2026), same architecture, run as a drop-in for v3 (same 60 s rule) |
| `whisper-turbo` | mlx-whisper | v2t's alternative backend |
| `nemotron-3.5-stream` | mlx-audio | cache-aware streaming Nemotron 3.5, multilingual |
| `voxtral-rt-4bit` | mlx-audio | Mistral Voxtral Mini 4B Realtime, natively streaming, 4-bit |
| `qwen3-asr-1.7b` (and `-8bit`) | mlx-audio | best open model on the 2026 Open ASR Leaderboard, offline |

Not in the grid, because no MLX runtime runs them faithfully today (2026-09-29):

- `nvidia/parakeet-unified-en-0.6b`: the int8 MLX build targets a separate C++ engine and the
  other conversions are 3–6-bit mixes.
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
VIRTUAL_ENV=.venv uv pip install whisper-normalizer      # Parakeet and Whisper run in v2t's own venv

~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py prepare
.venv/bin/python utils/asr_grid/grid.py run --system parakeet-v3 --set ls-clean
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py run --system voxtral-rt-4bit --set wispr
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py chunk --system qwen3-asr-1.7b-8bit --set wispr
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py report
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/report_html.py --headline "..."
```

Run cells one at a time: two models on the GPU contaminate each other's timings. Cells resume
where they stopped. Models load offline from the Hugging Face cache; where huggingface.co is
blocked, download them elsewhere (`hf download <repo>` with `HF_HUB_CACHE` pointed at a folder)
and rsync that folder into `~/.cache/huggingface/hub`.

Everything is written under `~/.v2t/eval/grid` (owner-only): manifests, per-clip results with
transcripts, and `<date>-report.md`, which holds numbers only.

## Reading the numbers

- **Wait** is seconds from release to the final text: the whole-file decode for an offline
  system, the last push plus flush for a streaming one (everything earlier was fed and decoded
  while "recording"). For `parakeet-v3` it follows v2t's own 60 s rule.
- **`<system>+chunked`** gives a whole-file system the same 60 s rule. Under 60 s it is the
  whole-file run. From 60 s up, the recording is cut every ~30 s at the quietest 100 ms within 5 s
  of the mark (the splitter mlx-audio's Qwen3-ASR uses for long files), each piece is decoded as
  soon as its cut is known, and only the last piece is left after release. The wait counts any
  piece still queued at release. `grid.py chunk` writes these to `<system>.chunked.jsonl` beside
  the whole-file results; a chunked row is scored but never votes in the dictation consensus, so
  adding one moves no other number.
- **RTF** is compute over audio. A streaming system needs it well under 1 to keep up live.
- Streaming sessions are fed 0.5 s at a time and drained between feeds; the drain for mlx-audio
  sessions reads their queue state, which is pinned to mlx-audio 0.5.7.
