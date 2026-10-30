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
| `parakeet-v3-8bit` | parakeet-mlx | Parakeet v3 as v2t's `parakeet` backend loads it since 0.5.15 (8-bit), whole-file |
| `bark-3.0` (and `-4bit`, `-coreml`) | bark | Conway Research's Underdog Bark 3.0 (October 2026): Parakeet v3 retrained through Parakeet Ultra, a 163 MB `model.bark`, English only. MLX through its own `bark_mlx.py` (mlx-audio's Parakeet graph, unpacked to fp16 or 4-bit); Core ML through its `bark_coreml.py` (encoder on the Neural Engine, numpy decoder, audio over 15 s cut at pauses). Each load of its `.mlpackage` recompiles for 5 to 6 minutes. Phone candidate |
| `bark-3.0-plus` (and `-plus-coreml`), `bark-3.0-clean` | bark | Bark 3.0 Plus (180 MB) and Clean, Plus trained to drop fillers and false starts (verbatim references count each drop) |
| `bark-3.0-pro` (and `-pro-4bit`, `-pro-coreml`) | bark, coremltools | Bark 3.0 Pro, bf16 (1.25 GB). Its Core ML files have FluidAudio's Parakeet v3 layout, so `-pro-coreml` runs them through v2t's own `parakeet-coreml` decode, compiled once with `xcrun coremlcompiler compile` into `~/.v2t/eval/grid-models/underdog-bark-3.0-pro-coreml` (encoder renamed `Encoder_v2.mlmodelc`) |
| `parakeet-unified-en` | parakeet-mlx | NVIDIA's English Parakeet Unified, offline mode only: `littlebearlabs/parakeet-unified-en-0.6b-mlx` (fp32, NeMo layout) mapped onto stock parakeet-mlx by `grid.load_nemo_layout` and cast to bf16 like every parakeet-mlx row. Its streaming mode is not run |
| `nemotron-unified` (and `-int8`, `-auto`) | fluidaudio | NVIDIA's Nemotron-Labs Unified ASR 0.6B, the multilingual (25 European languages) Parakeet Unified, offline on Core ML through FluidAudio's Swift `UnifiedAsrManager`: `FluidInference/nemotron-labs-unified-asr-0.6b-coreml`. Told each clip's language as its prompt (`en`, `es`); `-int8` is the half-size encoder, `-auto` lets the model pick the language. No MLX conversion exists (2026-10-29) |
| `nemotron-unified-stream-1.12` (and `-0.56`) | fluidaudio | the same model streaming through `StreamingUnifiedAsrManager` at 1.12 s and 0.56 s latency (encoders `[70, 7, 7]` and `[70, 2, 5]`). Streaming is buffered: every chunk re-encodes 5.6 s of left context, so each row also records the cost per step |
| `parakeet-v3-fluidaudio` | fluidaudio | the `parakeet-v3-coreml` files through FluidAudio's Swift decode, as the iPhone runs them: the like-for-like runtime for the rows above. It scores about 0.5 points worse pooled than `parakeet-v3-coreml` on the same files (2026-10-29) |

Each cell from 2026-10-14 also records MLX's peak memory per clip (weights included), the
report's `peak` column.

Not in the grid, because no MLX runtime runs them faithfully today (2026-09-29):

- `nvidia/nemotron-speech-streaming-en-0.6b` via `nemotron-asr-mlx` 0.2.0: its streaming path
  lacks the pre-encode cache and dropped words (45% WER streamed against 20% whole-file on the
  same 28 s LibriSpeech clip). mlx-audio's Nemotron session expects the multilingual prompt layer,
  so `nemotron-3.5-stream` is the cache-aware candidate.

## Clip sets

`ls-clean`, `ls-other` (LibriSpeech test, openslr.org), `fleurs-es` (FLEURS es_419 test): 150
labelled clips each, seeded. Every labelled set is scored the way the
[Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard) scores it:
its normalisers and its compound-merging alignment, copied into [`oasr/`](oasr/) at a pinned
commit, so a "to night" against "tonight" costs nothing and the numbers compare with its own
and with model cards that use its code. FLEURS references lose their parentheses, as in the
leaderboard's copy (the normaliser would otherwise delete the words inside, #76). Each row
carries a 95% interval from resampling its clips: on 150 clips it is about 1.5 points wide
on LibriSpeech, so gaps smaller than that are ties. `wispr`: the 208
dictations exported by `../wisprflow_benchmarking_profiling`, which have no ground truth; each
system is scored against the consensus (medoid) of the other systems, its own model family left out. That
measures agreement, not correctness. Wispr Flow takes part through a local script (kept out of the repo), which sends each clip to its own
service (`wispr-flow-api`); the text its app stored is its final output, often formatted or truncated, and no longer votes.

Meetings and earnings calls come twice, fetched by `fetch_noisy.py`:

| set | what | compares with |
|---|---|---|
| `ami-sdm` | AMI on the room microphone, as a laptop hears a meeting; 150 clips from 3 meetings | nothing published (the leaderboard uses headsets) |
| `ami-ihm` | the leaderboard's `AMI-Cleaned`: each speaker's headset, clips under 1 s removed; 150 clips from all 16 test meetings | the leaderboard's AMI column and most model cards |
| `earnings22` | earnings calls in short chunks with the original transcripts (`<unk>`, `<inaudible>`); 150 clips from 3 calls | the original Earnings22 numbers on older cards |
| `earnings22-aa` | the leaderboard's `Earnings22-Cleaned-AA-chunked`: 6 calls, 341 chunks, corrected transcripts, scored per call | the leaderboard's Earnings22 column |

On the same 127 AMI segments Parakeet v3 makes 12.1% errors on the headset and 34.9% on the
room microphone, so an 8% AMI on a model card and our 30% are not in conflict.

`<set>-full` (`ls-clean-full`, `ls-other-full`, `fleurs-es-full`, and `ami-ihm-full` after
`fetch_noisy.py --full ami-ihm`) is the whole test split: run a shortlisted model on it when a
decision needs the leaderboard's own precision (Parakeet v3 on LibriSpeech clean took about
20 minutes on a loaded M4 Pro). Its full-set numbers then match the leaderboard's: 1.48 / 3.14 /
3.31% against 1.52 / 3.13 / 3.25%. Prefer a labelled set whenever one fits the question. `silver.py`
builds a reference for the unlabelled dictations from three strong systems, but silver text cannot
reward a name or vocabulary fix the voters never got right, so judge dictionary and cleanup changes
on labelled sets. `cleanup_bench.py run|report` scores v2t's cleanup on its own: WER of raw against
cleaned text on the labelled sets, plus formatted WER on Earnings22.

## Run

Each runtime lives in its own environment so their pins never meet v2t's lock:

The `fluidaudio` rows run a small Swift program, [`fa_helper`](fa_helper/Sources/main.swift), that
keeps FluidAudio's models loaded and takes one clip per line; build it once, and put the Core ML
files where `grid.NEMOTRON_UNIFIED_DIR` points (FluidAudio's Parakeet v3 files are read from its own
folder, as v2t does):

```bash
swift build -c release --package-path utils/asr_grid/fa_helper
hf download FluidInference/nemotron-labs-unified-asr-0.6b-coreml --local-dir ~/.v2t/eval/grid-models/nemotron-unified-coreml \
  --include 'coreml/*.json' 'coreml/nemotron_unified_decoder.mlmodelc/*' 'coreml/nemotron_unified_joint_decision_single_step.mlmodelc/*' \
  'coreml/nemotron_unified_encoder.mlmodelc/*' 'coreml/nemotron_unified_encoder_int8.mlmodelc/*' \
  'coreml/nemotron_unified_encoder_streaming_70_7_7.mlmodelc/*' 'coreml/nemotron_unified_encoder_streaming_70_2_5.mlmodelc/*'
.venv/bin/python utils/asr_grid/grid.py run --system nemotron-unified --set fleurs-es
```

```bash
SCORE="kaldialign>=0.12 num2words regex"  # the leaderboard scorer in oasr/
uv venv ~/.v2t/eval/grid-envs/mlxaudio && VIRTUAL_ENV=~/.v2t/eval/grid-envs/mlxaudio \
  uv pip install mlx-audio==0.5.7 soundfile ${=SCORE}
VIRTUAL_ENV=~/.v2t/eval/grid-envs/mlxaudio uv pip install sentencepiece  # Cohere's tokenizer
VIRTUAL_ENV=.venv uv pip install ${=SCORE} pyyaml  # Parakeet and Whisper run in v2t's own venv
uv venv ~/.v2t/eval/grid-envs/phonon && VIRTUAL_ENV=~/.v2t/eval/grid-envs/phonon \
  uv pip install 'fermion-research[mlx]==0.2.11' soundfile ${=SCORE}

uv venv ~/.v2t/eval/grid-envs/bark && VIRTUAL_ENV=~/.v2t/eval/grid-envs/bark \
  uv pip install mlx-audio==0.5.7 coremltools==9.0 constriction==0.5.0 soundfile soxr whisper-normalizer
# Bark's repositories go in ~/.v2t/eval/grid-models/underdog-bark-3.0{,-plus,-clean,-pro} (hf download elsewhere, then rsync)

~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py prepare
.venv/bin/python utils/asr_grid/grid.py run --system parakeet-v3 --set ls-clean
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py run --system voxtral-rt-4bit --set wispr
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py chunk --system qwen3-asr-1.7b-8bit --set wispr
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/grid.py report
~/.v2t/eval/grid-envs/mlxaudio/bin/python utils/asr_grid/report_html.py --headline "..."
.venv/bin/python utils/asr_grid/grid.py race --systems parakeet-v3-coreml,nemotron-unified --set ls-clean --limit 60 --tag race-1029
.venv/bin/python utils/asr_grid/grid.py agree --system nemotron-unified-stream-1.12 --against nemotron-unified
.venv/bin/python utils/asr_grid/plot_wait.py               # the README's wait-vs-length chart
uv run --script utils/asr_grid/plot_pareto.py              # WER vs size and vs wait, short sets
```

When disk is tight, sweep models one at a time: download one, run every set, delete it with
Hugging Face's cache API (`scan_cache_dir().delete_revisions(...)`; moving the files to a trash
frees nothing), then the next.

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
- **`race`** times systems against each other in one process, clip by clip, rotating their order
  each clip, and prints each one's per-clip wait ratio to the first system, per third of the run
  and overall, with the load, free memory and free disk before and after. Use it for any speed
  claim: the waits in a `run` cell move with whatever else the Mac is doing. It decodes whole
  files, so from 60 s up the app's waits are shorter than a race shows (its pieces leave only the
  last one after release); time that path with `grid.py chunk`. **`agree`** scores one
  system's text against another's, such as a stream against its own whole-file decode.
- **Streaming rows from FluidAudio** are fed one encoder chunk at a time (0.56 s or 0.16 s) and
  decoded as each chunk arrives, rather than in 0.5 s pushes; `step_p50_s` and `step_p90_s` are
  the cost of one chunk's step. Their `peak` is the helper's physical footprint, which leaves out
  weights the Neural Engine holds, so it is not comparable with MLX's. A long stream can fail
  with Core ML's "ANE op async execution has timed out"; the grid then restarts the helper,
  retries the clip once and marks the row `retried`.
- **RTF** is compute over audio. A streaming system needs it well under 1 to keep up live.
- Streaming sessions are fed 0.5 s at a time and drained between feeds; the drain for mlx-audio
  sessions reads their queue state, which is pinned to mlx-audio 0.5.7.

What the grid found for long dictations, Parakeet in 30 s pieces against today's stream, is in
[internal/streaming.md](../../internal/streaming.md#would-30-s-pieces-beat-the-5-s-stream-for-long-dictations).
