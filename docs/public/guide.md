# Guide

## Transcribe a file

File transcription requires [ffmpeg](https://ffmpeg.org/download.html). With [Homebrew](https://brew.sh), install it using `brew install ffmpeg`.

```bash
v2t transcribe memo.opus
v2t transcribe memo.opus > notes.txt
v2t transcribe --clean memo.opus
```

In a terminal, the first command prints the transcript and copies it to the clipboard. Redirecting the output writes plain text without copying it. Audio and video formats supported by ffmpeg work; pass several paths to transcribe several files.

Files skip LLM cleanup by default. `--clean` enables it; dictionary replacements still apply either way.

## Casual or strict cleanup

| Mode | Intended edit |
|---|---|
| Casual, the default | Punctuation, capitals, repeated words, "um" and "uh" |
| Strict | Also remove false starts and restructure sentences |
| Off | Skip the cleanup model |

Choose a mode in the menu's **Settings**, or for one terminal run:

```bash
v2t --strict
v2t --no-cleanup
```

Cleanup can make mistakes. Casual mode uses a word guard to limit changes; chunks that fail length or token-limit checks fall back to the raw transcript. Review important text. [Benchmarks](benchmarks.md) separates cleanup fidelity from speech recognition.

## History

```bash
v2t history
v2t history --last 3 --raw
v2t history standup
```

History keeps raw and cleaned text with timings and input details. **Copy Last Transcription** in the menu recovers text that landed in the wrong window.

By default, each new recording replaces the last saved recording. To transcribe it again:

```bash
v2t transcribe ~/.v2t/run/last-recording.wav
```

Turn off `behavior.save_history` or `behavior.keep_last_audio` in the [config](reference/config.md) to stop keeping those records.

## Dictionary

Add preferred spellings for names and jargon:

```bash
v2t dictionary add Parakeet
v2t dictionary add "my sequel => MySQL"
v2t dictionary apply transcript.txt
```

A plain term is a hint to the cleanup model. A `heard => written` entry applies a case-insensitive replacement after cleanup, including when cleanup is off. `apply` lets you check replacements on a text file, or on standard input when no file is given.

See the [CLI reference](reference/cli.md) for the full commands and options.

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-05 · commit `4d5dcb4` · verified against code._
