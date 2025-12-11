# `voice2text` | [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/lucharo)

[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![Downloads](https://static.pepy.tech/badge/voice2text/month)](https://pepy.tech/project/voice2text)
[![macOS](https://img.shields.io/badge/macOS-only-blue?logo=apple)](https://github.com/lucharo/voice2text)
[![Works on my machine](https://img.shields.io/badge/works-on%20my%20machine-brightgreen)](https://github.com/lucharo/voice2text)

Local voice-to-text with Whisper + LLM cleanup. Push-to-talk (Right ⌘), pastes at cursor.

Voice-to-text tools like [Whisper Flow](https://www.wispr.ai/), [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper), and [VoiceInk](https://www.voiceink.app/) are becoming increasingly popular. It's a testament to our times that in 2025, ~270 lines of Python with local Whisper and a small `ollama` language model (Qwen 2.5-3B) can deliver a comparable experience on consumer hardware. Such tooling would have been unimaginable 3 years ago. This project is a proof of concept to demonstrate just that.

> **Note:** Before anyone suggests splitting this into modules and submodules — this is an intentional design choice to keep everything in a single readable file.

> **Note 2:** This is macOS-only by design. We use:
> - **[mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)** — optimized for Apple Silicon
> - **osascript** — for simulating Cmd+V paste via System Events
> - **pbcopy/pbpaste** — macOS clipboard
> - **[nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli)** — macOS media control
> - **System Preferences** URLs for permissions
>
> You're welcome to fork this and make it work on Linux or Windows!

## Prerequisites

> Skip this if using **`pixi`** — it handles ollama automatically.

```bash
brew install ollama
ollama pull qwen2.5:3b
```

## Install

### uvx (easiest)

```bash
uvx voice2text
```

Or from GitHub:

```bash
uvx --from git+https://github.com/lucharo/voice2text voice2text
```

### pip

```bash
pip install voice2text
v2t
```

### Development install

```bash
git clone https://github.com/lucharo/voice2text.git
cd voice2text
uv sync
uv run v2t
```

### Pixi

Pixi handles the ollama dependency automatically:

```bash
git clone https://github.com/lucharo/voice2text.git
cd voice2text
pixi run ollama pull qwen2.5:3b
pixi run v2t
```

> **Note:** We don't publish to conda-forge/pixi channels yet, but may in the future.

## Usage

```bash
v2t                      # strict mode (restructures sentences)
v2t --casual             # light cleanup (punctuation only)
v2t --pause-music        # pause media while recording (macOS only, requires nowplaying-cli via brew)
```

Hold **Right Command** to record, release to transcribe and paste.

### Strict vs Casual Mode

| Raw transcription | Strict | Casual |
|-------------------|--------|--------|
| "Hey um I'll see you tomorrow at 9 actually no make it 10" | "Hey, I'll see you tomorrow at 10." | "Hey, I'll see you tomorrow at 9, actually no, make it 10." |
| "So basically I was thinking we could um you know maybe try the other approach" | "I was thinking we could try the other approach." | "So basically, I was thinking we could maybe try the other approach." |


**Strict** (default): Removes filler words, restructures for clarity, condenses.

**Casual**: Only adds punctuation and removes "um/uh", keeps your phrasing.

### `--pause-music` (macOS only)

Pauses any playing media while recording and resumes after. Requires:

```bash
brew install nowplaying-cli
```

Not available via pixi/conda-forge for now, maybe will publish later!

