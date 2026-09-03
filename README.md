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
> harness, and an optional one-file menu-bar app.

> **Design tenet — be communicative.** An ergonomic tool is an expressive one: every action gets
> immediate, visible feedback. The optional menu-bar icon tracks live state (off · loading · ready ·
> recording · transcribing · cleaning · error), so you always know whether the tool heard you.

## What you get

- **Push-to-talk** — hold Right ⌘ (configurable), release to transcribe + paste.
- **Parakeet (MLX)** transcription by default — ~10× faster than Whisper on Apple Silicon, English + 24 European languages. Whisper stays available as a fallback for rare languages/accents.
- **In-process LLM cleanup** via mlx-lm (`Qwen2.5-1.5B-Instruct`) — fixes punctuation, removes fillers while using about 1.3 GB less model memory than the previous 4B default. No Ollama, no daemon. Strict or casual. (Ollama optional — see [Cleanup engine](#cleanup-engine).)
- **Pastes at cursor**, restoring your previous clipboard.
- **File transcription** — `v2t transcribe memo.opus` runs the same local models over audio you already have (see [Transcribing files](#transcribing-files)).
- **One config file** at `~/.v2t/config.toml`, plus a JSONL **history** of every transcription.
- **Optional one-file Swift menu** — native permissions, instant state, and quick links; no window or Xcode project.

## Install

Requires **macOS on Apple Silicon** (MLX). Parakeet transcription and in-process mlx-lm cleanup ship
as dependencies, with no daemon. The models download from Hugging Face on first launch, then remain
in the local cache:

```bash
uv tool install voice2text   # Parakeet STT + in-process Qwen2.5 cleanup
v2t setup                    # optional: pick models, detect Ollama, write config
v2t
```

Prefer Whisper for transcription? Add the extra (quote the brackets — zsh treats them as globs):

```bash
uv tool install 'voice2text[whisper]'   # adds the Whisper backend; select it in config
```

<details>
<summary>Other install methods (uvx, pip, dev)</summary>

```bash
# quick try (fresh venv each run — slower startup)
uvx --from voice2text v2t

# pip
pip install voice2text && v2t

# from source
git clone https://github.com/lucharo/voice2text.git && cd voice2text
uv sync --no-dev && uv run v2t
```
</details>

## Usage

```bash
v2t                      # run push-to-talk (strict cleanup, parakeet)
v2t --casual             # light cleanup (punctuation + fillers only)
v2t --no-cleanup         # paste raw transcription, skip the LLM
v2t --backend whisper    # use the whisper backend for this run
v2t --pause-music        # pause media while recording (needs nowplaying-cli)

v2t transcribe memo.opus # transcribe a file you already have (no microphone)

v2t setup                # guided config: pick models, detect Ollama
v2t history              # last 10 transcriptions; `v2t history <term>` searches, --raw, --json
v2t status               # running / idle (also used by the menu app)
v2t stop                 # stop a running v2t gracefully  (--force if it is stuck)
v2t config               # show resolved config + paths  (--init writes a template)
v2t menubar install      # optional: compile + open the tiny native menu app
v2t service install      # optional: start that menu app at login
```

Hold **Right Command** to record, release to transcribe and paste.

### Transcribing files

`v2t transcribe` points the same local models at audio already on disk — anything ffmpeg reads
(`.opus`, `.m4a`, `.mp3`, video files too), no microphone or permissions involved.

```bash
v2t transcribe memo.opus              # prints the transcript, copies it to the clipboard
v2t transcribe memo.opus > notes.txt  # redirected: clean text, no clipboard copy
v2t transcribe *.m4a                  # several files, each under a `# filename` heading
v2t transcribe --clean memo.opus      # add the LLM cleanup pass (--casual / --strict imply it)
```

Files transcribe **verbatim** by default: cleanup rewrites, and that is rarely what you want for
someone else's voice note. Every step reports live elapsed time — a 3½-minute WhatsApp note takes
about 11s with Parakeet on an M1 Max (~19× realtime). Each result is appended to the same
[history](#config--v2t) as your dictations, with the file it came from (`save_history = false` to opt out).

### Strict vs Casual

| Raw transcription | Strict | Casual |
|-------------------|--------|--------|
| "Hey um I'll see you tomorrow at 9 actually no make it 10" | "Hey, I'll see you tomorrow at 10." | "Hey, I'll see you tomorrow at 9, actually no, make it 10." |
| "So basically I was thinking we could um you know maybe try the other approach" | "I was thinking we could try the other approach." | "So basically, I was thinking we could maybe try the other approach." |

**Strict** (default) removes fillers, restructures for clarity. **Casual** only adds punctuation and removes "um/uh", keeping your phrasing.

Both modes send the model a short system prompt plus these worked examples as prior turns, so even a
small model treats your dictation as text to clean rather than a question to answer.

### History

Every dictation and file transcription is appended to `~/.v2t/history/transcriptions.jsonl`
(raw text, cleaned text, models, timings). Read it back without opening the file:

```bash
v2t history                 # the last 10, oldest first, with timings
v2t history -n 3 --raw      # show the raw transcription next to the cleaned one
v2t history standup         # entries whose raw or clean text mentions "standup"
v2t history --json -n 0     # every record as JSONL, for jq and friends
```

The menu-bar app shows the last transcription too, with a **Copy Last Transcription** action for
when the paste landed in the wrong window.

## Config — `~/.v2t/`

Everything lives in one directory (override with `$V2T_HOME`, or `$XDG_CONFIG_HOME/v2t`):

```
~/.v2t/
  config.toml                    # all settings (v2t config --init to create)
  history/transcriptions.jsonl   # every transcription + metadata (toggle in config)
  run/                           # private runtime status + log
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
(`Qwen2.5-1.5B-Instruct`, non-thinking) — no daemon, no HTTP, same MLX stack as transcription.

Have memory to spare (24 GB+)? The Qwen3.5 small models follow the cleanup rules more reliably and
are non-thinking by default; the 4B one costs roughly half a second per dictation on an M1 Max:

```toml
[cleanup]
model = "mlx-community/Qwen3.5-4B-4bit"   # or Qwen3.5-2B-4bit; downloads on next launch
```

Already running **[Ollama](https://ollama.com)**? Switch to it (`v2t setup` offers this when it
detects Ollama, or edit the config):

```toml
[cleanup]
engine = "ollama"
model = "qwen3:4b-instruct-2507"   # then: ollama pull qwen3:4b-instruct-2507
```

Either way, use a **non-thinking** model — a model that emits `<think>` blocks will paste its
reasoning. The defaults don't.

## Optional menu-bar app

```bash
v2t menubar install      # compile the bundled Swift file into ~/Applications/Voice2Text.app
```

The optional app is a single, inspectable Swift source file — no window, Xcode project, AppleScript,
or separate settings system. It exists because macOS only grants microphone access to a real app
identity. The menu requests the two native grants, starts one long-running Python process, shows
state immediately (the icon turns red while recording), previews the last transcription with a
copy action, and links to config, history, and log. Run `v2t` in a terminal instead if you do not
want the menu.

**Start v2t** loads Parakeet and the cleanup model once, then keeps them warm for every
transcription. To start the same menu app at login, install the optional per-user LaunchAgent:

```bash
v2t service install       # install + start ~/Library/LaunchAgents/com.lucharo.voice2text.plist
v2t service status
v2t service uninstall
```

The service starts the same `Voice2Text.app` bundle, so manual and login launches share one stable
permission identity. The engine lock still prevents duplicate Python processes.

**Permissions.** v2t needs **Microphone** (record) and **Accessibility** (global hotkey + paste). A
terminal launch uses your terminal's grants. The menu app requests its own grants and
shows their live state as flat rows; click a missing row to open the exact Settings pane.

## Models & benchmarks

The contributor-only `just bench` harness writes `~/.v2t/benchmarks/results/<date>-<host>.md` — two
tables (speech-to-text RTF and cleanup TTFT/total), one column per model. It lives in the dev group,
not the installed CLI. See [`benchmarks/`](benchmarks/) for the method and defaults.

| | default | why |
|---|---|---|
| transcription | `parakeet-tdt-0.6b-v3` | fastest on Apple Silicon, multilingual |
| cleanup | `Qwen2.5-1.5B-Instruct` (mlx-lm) | 831 MB active in the local cleanup benchmark; non-thinking, no daemon |
| cleanup (quality) | `Qwen3.5-4B-4bit` (mlx-lm) | opt-in via config; better instruction following, ~2.3 GB |

> This is **macOS / Apple Silicon-only** by design (MLX, native pasteboard/event APIs,
> `nowplaying-cli`, System Settings permission URLs). Fork it for Linux/Windows if you like.

Contributor questions, including how releases are published, are covered in the
[`FAQ`](docs/faq/README.md).
