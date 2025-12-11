# voice2text

[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![Downloads](https://static.pepy.tech/badge/voice2text/month)](https://pepy.tech/project/voice2text)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/lucharo)

Local voice-to-text with Whisper + LLM cleanup. Push-to-talk, pastes at cursor.

> **Note:** Before anyone suggests splitting this into modules and submodules — this is an intentional design choice. I want to demonstrate that in December 2025, you can have a fully local voice-to-text system with automatic cleanup and correction, running almost instantly on consumer hardware, all in ~270 lines of Python.

## Install

### Option 1: Pixi (recommended)

```bash
pixi run ollama pull qwen2.5:3b
pixi run v2t
```

### Option 2: UV

```bash
brew install ollama
ollama pull qwen2.5:3b
uv sync
uv run v2t
```

## Usage

```bash
v2t                      # strict mode (restructures sentences)
v2t --casual             # light cleanup (punctuation only)
v2t --pause-music        # pause media while recording (macOS only, requires nowplaying-cli)
```

Hold **Right Command** to record, release to transcribe and paste.

### `--pause-music` (macOS only)

Pauses any playing media while recording and resumes after. Requires:

```bash
brew install nowplaying-cli
```

Not available via pixi/conda-forge.
