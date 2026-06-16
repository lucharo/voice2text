# `voice2text`

[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![Downloads](https://static.pepy.tech/badge/voice2text/month)](https://pepy.tech/project/voice2text)
[![Total Downloads](https://static.pepy.tech/badge/voice2text)](https://pepy.tech/project/voice2text)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue?logo=apple)](https://github.com/lucharo/voice2text)
[![Works on my machine](https://img.shields.io/badge/works-on%20my%20machine-brightgreen)](https://github.com/lucharo/voice2text)

Local, MLX-first voice-to-text. Hold **Right ⌘**, talk, release — it transcribes with
[Parakeet](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3), cleans the text up with a
small local LLM, and pastes at your cursor. No cloud, no network, no account.

Voice-to-text tools like [Wispr Flow](https://wisprflow.ai/), [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper),
and [VoiceInk](https://www.voiceink.app/) are great until the network gets in the way — Wispr Flow
[isn't compatible with most VPNs](https://docs.wisprflow.ai/troubleshooting), so behind a corporate
SSL-intercepting gateway (Zscaler and friends) it stalls or fails. Going local makes that whole class
of problem disappear: zero network dependency means the VPN is irrelevant. Speech models are good
enough now that the basics fit in a small Python package on consumer hardware.

> **Heritage:** this started as a single `voice2text.py` under 300 lines — that proof-of-concept is
> preserved forever at the [`nano`](https://github.com/lucharo/voice2text/releases/tag/nano) tag.
> From `0.3.0` it's a small, modular package: pluggable MLX backends, one config file, a benchmark
> harness, and a SwiftBar menu-bar toggle.

## What you get

- **Push-to-talk** — hold Right ⌘ (configurable), release to transcribe + paste.
- **Parakeet (MLX)** transcription by default — ~10× faster than Whisper on Apple Silicon, English + 24 European languages. Whisper stays available as a fallback for rare languages/accents.
- **Local LLM cleanup** via Ollama (`qwen3:4b-instruct-2507`) — fixes punctuation and removes fillers. Strict or casual.
- **Pastes at cursor**, restoring your previous clipboard.
- **One config file** at `~/.v2t/config.toml`, plus a JSONL **history** of every transcription.
- **SwiftBar plugin** — menu-bar toggle, status, and quick links to your config/history.
- **Benchmark harness** — `v2t bench` writes a per-machine markdown grid of model speeds.

## Install

Requires **macOS on Apple Silicon** (MLX) and **[Ollama](https://ollama.com)** for cleanup.

```bash
brew install ollama
ollama pull qwen3:4b-instruct-2507
```

Then install v2t with the backend you want (quote the brackets — zsh treats them as globs):

```bash
uv tool install 'voice2text[parakeet]'   # recommended — Parakeet (default backend)
uv tool install 'voice2text[whisper]'    # Whisper instead (no Parakeet)
uv tool install 'voice2text[all]'        # both, switch via config
v2t
```

> **Note on extras:** MLX is an explicit extra so the install stays Mac-first and you pick exactly
> one engine. A bare `voice2text` (no extra) installs no backend and tells you to add `[parakeet]`.
> ([PEP 771](https://peps.python.org/pep-0771/) "default extras" would let a bare install imply
> Parakeet automatically, but it isn't supported by uv/hatchling yet.)

<details>
<summary>Other install methods (uvx, pip, dev, pixi)</summary>

```bash
# quick try (fresh venv each run — slower startup)
uvx --from 'voice2text[parakeet]' v2t

# pip
pip install 'voice2text[parakeet]' && v2t

# from source
git clone https://github.com/lucharo/voice2text.git && cd voice2text
uv sync --extra parakeet && uv run v2t

# pixi (handles ollama; installs the parakeet extra)
pixi run ollama pull qwen3:4b-instruct-2507
pixi run v2t
```
</details>

## Usage

```bash
v2t                      # run push-to-talk (strict cleanup, parakeet)
v2t --casual             # light cleanup (punctuation + fillers only)
v2t --no-cleanup         # paste raw transcription, skip the LLM
v2t --backend whisper    # use the whisper backend for this run
v2t --pause-music        # pause media while recording (needs nowplaying-cli)

v2t status               # running / idle (used by the SwiftBar plugin)
v2t stop                 # stop a running v2t
v2t config               # show resolved config + paths  (--init writes a template)
v2t bench                # benchmark STT + cleanup models on this machine
```

Hold **Right Command** to record, release to transcribe and paste.

### Strict vs Casual

| Raw transcription | Strict | Casual |
|-------------------|--------|--------|
| "Hey um I'll see you tomorrow at 9 actually no make it 10" | "Hey, I'll see you tomorrow at 10." | "Hey, I'll see you tomorrow at 9, actually no, make it 10." |
| "So basically I was thinking we could um you know maybe try the other approach" | "I was thinking we could try the other approach." | "So basically, I was thinking we could maybe try the other approach." |

**Strict** (default) removes fillers, restructures for clarity. **Casual** only adds punctuation and removes "um/uh", keeping your phrasing.

## Config — `~/.v2t/`

Everything lives in one directory (override with `$V2T_HOME`, or `$XDG_CONFIG_HOME/v2t`):

```
~/.v2t/
  config.toml                    # all settings (v2t config --init to create)
  history/transcriptions.jsonl   # every transcription + metadata (toggle in config)
  run/                           # pid + status for the SwiftBar plugin
```

`config.toml` (every key optional — these are the defaults):

```toml
[transcription]
backend = "parakeet"   # parakeet (MLX) | whisper
model = ""             # blank = backend default

[cleanup]
enabled = true
model = "qwen3:4b-instruct-2507"   # any ollama model; use a non-thinking -instruct one
mode = "strict"        # strict | casual

[hotkey]
key = "cmd_r"          # cmd_r | cmd_l | alt_r | alt_l | ctrl_r | ctrl_l

[behavior]
pause_music = false
save_history = true
```

## SwiftBar menu-bar toggle

```bash
brew install swiftbar
cp swiftbar/v2t.5s.sh "$HOME/Library/Application Support/SwiftBar/Plugins/"   # your plugins folder
```

The menu shows running/idle, the current model · mode, a Start/Stop toggle, and links to open
your config and transcription history. **Start from the menu** needs SwiftBar to have Accessibility +
Input Monitoring permissions; otherwise start `v2t` in a terminal and use the menu for status/stop.

## Models & benchmarks

`v2t bench` writes `benchmarks/results/<date>-<host>.md` — two tables (speech-to-text RTF, and cleanup
TTFT/total), one column per model. Run it on each machine to build a grid. See
[`benchmarks/`](benchmarks/) for the method and defaults.

| | default | why |
|---|---|---|
| transcription | `parakeet-tdt-0.6b-v3` | fastest on Apple Silicon, multilingual |
| cleanup | `qwen3:4b-instruct-2507` | latest small instruct, non-thinking |

> This is **macOS / Apple Silicon-only** by design (MLX, `osascript` paste, `pbcopy`/`pbpaste`,
> `nowplaying-cli`, System Settings permission URLs). Fork it for Linux/Windows if you like.
