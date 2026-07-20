# `voice2text`

[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![Downloads](https://static.pepy.tech/badge/voice2text/month)](https://pepy.tech/project/voice2text)
[![Total Downloads](https://static.pepy.tech/badge/voice2text)](https://pepy.tech/project/voice2text)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue?logo=apple)](https://github.com/lucharo/voice2text)
[![Works on my machine](https://img.shields.io/badge/works-on%20my%20machine-brightgreen)](https://github.com/lucharo/voice2text)

Local, MLX-first voice-to-text. Hold **Right ⌘**, talk, release — it transcribes with
[Parakeet](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3), cleans the text up with a
small local LLM, and pastes at your cursor. No cloud or account; after the one-time model download,
it runs without a network connection.

Voice-to-text tools like [Wispr Flow](https://wisprflow.ai/), [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper),
and [VoiceInk](https://www.voiceink.app/) are great until the network gets in the way — Wispr Flow
[isn't compatible with most VPNs](https://docs.wisprflow.ai/troubleshooting), so behind a corporate
SSL-intercepting gateway (Zscaler and friends) it stalls or fails. Once the models are cached, going
local makes that whole class of problem disappear: the VPN is irrelevant. Speech models are good
enough now that the basics fit in a small Python package on consumer hardware.

> **Heritage:** this started as a single `voice2text.py` under 300 lines — that proof-of-concept is
> preserved forever at the [`nano`](https://github.com/lucharo/voice2text/releases/tag/nano) tag.
> From `0.3.0` it's a small, modular package: pluggable MLX backends, one config file, a benchmark
> harness, and a SwiftBar menu-bar toggle.

> **Design tenet — be communicative.** An ergonomic tool is an expressive one: every action gets
> immediate, visible feedback. The menu-bar icon tracks live state (off · loading · ready ·
> recording · transcribing · cleaning · error) and repaints the instant anything changes, so you
> always know whether the tool heard you.

## What you get

- **Push-to-talk** — hold Right ⌘ (configurable), release to transcribe + paste.
- **Parakeet (MLX)** transcription by default — ~10× faster than Whisper on Apple Silicon, English + 24 European languages. Whisper stays available as a fallback for rare languages/accents.
- **In-process LLM cleanup** via mlx-lm (`Qwen3-4B-Instruct-2507`) — fixes punctuation, removes fillers. No Ollama, no daemon. Strict or casual. (Ollama optional — see [Cleanup engine](#cleanup-engine).)
- **Pastes at cursor**, restoring your previous clipboard.
- **One config file** at `~/.v2t/config.toml`, plus a JSONL **history** of every transcription.
- **SwiftBar plugin** — menu-bar toggle, status, and quick links to your config/history.

## Install

Requires **macOS on Apple Silicon** (MLX). Parakeet transcription and in-process mlx-lm cleanup ship
as dependencies, with no daemon. The models download from Hugging Face on first launch, then remain
in the local cache:

```bash
uv tool install voice2text   # Parakeet STT + in-process Qwen3 cleanup
v2t setup                    # optional: pick models, detect Ollama, write config
v2t
```

Prefer Whisper for transcription? Add the extra (quote the brackets — zsh treats them as globs):

```bash
uv tool install 'voice2text[whisper]'   # adds the Whisper backend; select it in config
```

<details>
<summary>Other install methods (uvx, pip, dev, pixi)</summary>

```bash
# quick try (fresh venv each run — slower startup)
uvx voice2text

# pip
pip install voice2text && v2t

# from source
git clone https://github.com/lucharo/voice2text.git && cd voice2text
uv sync --no-dev && uv run v2t

# pixi
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

v2t setup                # guided config: pick models, detect Ollama
v2t status               # running / idle (used by the SwiftBar plugin)
v2t stop                 # stop a running v2t
v2t config               # show resolved config + paths  (--init writes a template)
v2t service install      # optional: keep v2t warm and start it at login
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
engine = "mlx"         # mlx (in-process via mlx-lm) | ollama
model = ""             # blank = engine default
mode = "strict"        # strict | casual

[hotkey]
key = "cmd_r"          # cmd_r | cmd_l | alt_r | alt_l | ctrl_r | ctrl_l

[behavior]
pause_music = false
save_history = true
```

### Cleanup engine

Cleanup runs **in-process via [mlx-lm](https://github.com/ml-explore/mlx-lm)** by default
(`Qwen3-4B-Instruct-2507`, non-thinking) — no daemon, no HTTP, same MLX stack as transcription.

Already running **[Ollama](https://ollama.com)**? Switch to it (`v2t setup` offers this when it
detects Ollama, or edit the config):

```toml
[cleanup]
engine = "ollama"
model = "qwen3:4b-instruct-2507"   # then: ollama pull qwen3:4b-instruct-2507
```

Either way, use a **non-thinking** model — a model that emits `<think>` blocks will paste its
reasoning. The defaults don't.

## SwiftBar menu-bar toggle

```bash
brew install swiftbar
v2t swiftbar             # install/update the bundled, hackable shell plugin
```

The menu shows a colored live-state icon (off · loading · ready · recording · transcribing ·
cleaning · error), the active models, a Start/Stop toggle, a **Permissions** submenu, and links to
open your config, transcription history, and log. The installed plugin remains a normal shell file
in SwiftBar's Plugins folder, so it is easy to inspect or change.

SwiftBar's normal **Start v2t** action already launches one long-running process: Parakeet and the
cleanup model load once, then stay warm for every transcription. To also start that process at login,
install the optional per-user LaunchAgent:

```bash
v2t service install       # install + start ~/Library/LaunchAgents/com.lucharo.voice2text.plist
v2t service status
v2t service uninstall     # stop it and return SwiftBar to direct-launch mode
```

The service uses the same lock and status files as direct mode, so SwiftBar detects it automatically.
It runs the exact Python executable shown during installation. If macOS lists that executable as a
separate app in Privacy & Security, grant it the same three permissions.

**Permissions.** v2t needs three grants, given to the app that *launches* it (your terminal, or
SwiftBar if you use "Start v2t"): **Microphone** (record), **Accessibility** + **Input Monitoring**
(hotkey + paste). The Permissions submenu opens each pane — grant them, then **restart the launching
app** (macOS only applies the grant on relaunch). If audio comes back silent, that's a missing
Microphone grant: v2t says so and opens the Mic pane.

## Models & benchmarks

The contributor-only `just bench` harness writes `~/.v2t/benchmarks/results/<date>-<host>.md` — two
tables (speech-to-text RTF and cleanup TTFT/total), one column per model. It lives in the dev group,
not the installed CLI. See [`benchmarks/`](benchmarks/) for the method and defaults.

| | default | why |
|---|---|---|
| transcription | `parakeet-tdt-0.6b-v3` | fastest on Apple Silicon, multilingual |
| cleanup | `Qwen3-4B-Instruct-2507` (mlx-lm) | latest small instruct, non-thinking, no daemon |

> This is **macOS / Apple Silicon-only** by design (MLX, `osascript` paste, the native pasteboard,
> `nowplaying-cli`, System Settings permission URLs). Fork it for Linux/Windows if you like.
