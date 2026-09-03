---
name: v2t-transcribe
description: >
  Turn an audio or video file into text on-device with `v2t transcribe`
  (voice2text — Parakeet on MLX, Apple Silicon). Use for any "transcribe this
  file/audio/recording/voice note" request, for one file or many, and whenever a
  task needs the text of a recording rather than the microphone. Covers the
  command forms, verbatim vs LLM cleanup, stdout/clipboard behaviour, history,
  speed, and what to do when v2t or ffmpeg is missing. Triggers: "transcribe",
  "transcribe this", ".m4a/.opus/.wav/.mp3 to text", "what does this recording say".
allowed-tools:
  - Bash
  - Read
---

# Transcribe a file with v2t

`v2t transcribe` runs speech-to-text fully on-device. **Never upload audio to a cloud STT API**
(OpenAI, Deepgram, …), even when a key is in the environment — ask first if a cloud service seems
genuinely necessary.

## The command

```bash
v2t transcribe "<file>"                  # transcript → stdout (+ clipboard when interactive)
v2t transcribe "<file>" > notes.txt      # redirected: clean text, no clipboard copy
v2t transcribe a.m4a b.opus              # several files, each under a `# filename` heading
v2t transcribe --clean "<file>"          # add the LLM cleanup pass (off by default)
v2t transcribe --casual "<file>"         # cleanup, punctuation + fillers only (implies --clean)
v2t transcribe --backend whisper "<f>"   # rare languages or heavy accents
v2t transcribe --model <hf-repo> "<f>"   # a specific model for the chosen backend
```

Anything ffmpeg reads works: `.wav`, `.m4a`, `.mp3`, `.opus`, and video files.

## What to expect

- **Verbatim by default.** Cleanup rewrites sentences, which is rarely wanted for someone else's
  voice note — pass `--clean` only when the user wants tidied prose.
- **Progress on stderr, transcript on stdout.** Each step prints live elapsed time, then a summary
  line (`✓ 713 words in 11.4s · 19× realtime`). Capture stdout alone to get clean text.
- **Speed.** Roughly 10–20× realtime with the default Parakeet backend on Apple Silicon — a
  3½-minute voice note in about 11s, including a few seconds of model load. Whisper is slower.
- **One process, many files.** The model loads once per invocation, so pass every file to a single
  command instead of looping or running parallel processes (it is GPU-bound either way).
- **History.** Every result is appended to `~/.v2t/history/transcriptions.jsonl` with its source
  path, unless the user set `save_history = false` in `~/.v2t/config.toml`.
- **Reading it back.** `v2t history` lists recent entries with timings, `v2t history <term>` searches
  raw and clean text, `--json` re-emits records. Prefer it over opening the JSONL.
- **Dictionary.** Names and jargon in `~/.v2t/dictionary.txt` are spelled exactly by the cleanup pass
  (`--clean`) and `heard => written` lines are applied even without it; `v2t dictionary add <term>`.

Long recordings can take a while — run them in the background rather than blocking, and read the
summary line when they finish.

## When it isn't there

| Symptom | Fix |
|---|---|
| `command not found: v2t` | `uv tool install voice2text` (Apple Silicon only). `transcribe` needs ≥ 0.3.0; while PyPI lags, install from this checkout: `uv tool install --force .` |
| Ran the repo's source but saw an older CLI | the global `v2t` is a separate install — `uv tool install --force .` after changing the source, or `uv run v2t …` from the repo root |
| `FFmpeg is not installed` | `brew install ffmpeg` — both backends decode through it |
| `whisper backend needs …` | `uv tool install 'voice2text[whisper]'` (quote the brackets in zsh) |
| `uv run v2t` outside this repo ran something else | with no project in cwd/parents, `uv run` execs the PATH copy — `cd` here first |

## Beyond one file

Pulling recordings out of Apple Voice Memos, categorising transcripts, and filing them into Drafts
or GitHub issues is a separate workflow that lives outside this repo — it calls `v2t transcribe`
for the transcription step.
