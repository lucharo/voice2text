# CLI

Use `v2t --help` or `v2t <command> --help` for usage. `v2t` and `v2t run` both start dictation.

| Command | Purpose |
|---|---|
| [`v2t`](#v2t) | Run push-to-talk dictation |
| [`transcribe`](#transcribe) | Transcribe audio or video files |
| [`history`](#history) | Read or search past transcriptions |
| [`dictionary`](#dictionary) | Manage terms and replacements |
| [`setup`](#setup) | Choose models interactively |
| [`status`](#status) | Show engine state |
| [`stop`](#stop) | Stop the engine |
| [`config`](#config) | Read or change configuration |
| [`menubar`](#menubar) | Install, open or build the menu app |
| [`service`](#service) | Manage the login item |
| [`update`](#update) | Check for updates and print upgrade commands |

## v2t

```bash
v2t --strict
```

| Option | Value | Effect |
|---|---|---|
| `--config` | path | Use this configuration file |
| `--backend` | `parakeet-coreml`, `parakeet`, `whisper`, `qwen3-asr` | Transcription backend |
| `--model` | model ID or Core ML folder | Override the transcription model |
| `--cleanup-engine` | `mlx`, `ollama` | Cleanup engine |
| `--cleanup-model` | model ID or Ollama tag | Override the cleanup model |
| `--no-cleanup` | | Skip LLM cleanup |
| `--casual` | | Light cleanup, the default |
| `--strict` | | Also restructure and remove false starts |
| `--pause-music` | | Pause media while recording; requires `nowplaying-cli` |

## transcribe

```bash
v2t transcribe memo.opus
```

| Argument or option | Value | Effect |
|---|---|---|
| `AUDIO …` | file paths | Files to transcribe; formats supported by ffmpeg |
| `--config` | path | Use this configuration file |
| `--backend` | `parakeet-coreml`, `parakeet`, `whisper`, `qwen3-asr` | Transcription backend |
| `--model` | model ID or Core ML folder | Override the transcription model |
| `--clean` | | Enable LLM cleanup, off by default for files |
| `--casual` | | Light cleanup; implies `--clean` |
| `--strict` | | Restructuring cleanup; implies `--clean` |

Requires the `ffmpeg` command. In a terminal, it prints the result and copies it to the clipboard. Redirected output is plain text without a clipboard copy. Dictionary replacements apply with cleanup on or off.

## history

```bash
v2t history standup --raw
```

| Argument or option | Value | Effect |
|---|---|---|
| `term` | text | Match raw or cleaned text |
| `--last`, `-n` | integer | Recent entries to show; default `10`, `0` for all |
| `--raw` | | Also show raw transcription |
| `--json` | | Print JSON lines |

## dictionary

```bash
v2t dictionary add "my sequel => MySQL"
```

| Subcommand | Arguments | Effect |
|---|---|---|
| `show` | | List terms and replacements; the default |
| `add` | term or `heard => written` | Add an entry |
| `apply` | optional text file | Apply replacements; read standard input if no file is given |
| `import-wispr` | optional `--db PATH` | Import from Wispr Flow's local dictionary database |

## setup

`v2t setup` prompts for models and writes `config.toml`. Run it in a terminal, or use `v2t config --init` for defaults without questions.

## status

`v2t status` prints a tab-separated line with state, models, cleanup mode, launch error and the last dictation's warning.

| State | Meaning |
|---|---|
| `off` | No engine running |
| `loading-stt`, `loading-cleanup` | Loading models |
| `idle` | Ready |
| `recording`, `transcribing`, `cleaning`, `delivering` | Dictation in progress |
| `cancelled`, `stopping` | Cancelled or shutting down |
| `launch-error` | Startup failed; read the error field |

## stop

`v2t stop` requests shutdown. `--force` kills the engine immediately.

## config

| Argument or option | Effect |
|---|---|
| `--init` | Write a commented file if none exists |
| `--path` | Print paths only |
| `--json` | Print paths, settings and model choices as JSON |
| `set SECTION.KEY VALUE …` | Change settings; multiple pairs are validated and written together |

```bash
v2t config set cleanup.mode strict
```

## menubar

| Argument or option | Effect |
|---|---|
| `install` | Compile into `~/Applications` and open; the default action |
| `open` | Open the installed app |
| `build PATH` | Build a portable bundle at a directory or `.app` path |
| `--identity` | Code-signing identity for `build` |

For a prebuilt app, use [Homebrew](../getting-started.md#the-menu-app-optional). `install` refuses when the Homebrew copy is present, to avoid conflicting permissions.

## service

| Subcommand | Effect |
|---|---|
| `install` | Install the login item and start the menu app |
| `start`, `stop` | Start or stop it now |
| `status` | Show whether it is loaded |
| `uninstall` | Remove the login item |

## update

`v2t update` checks for a newer release and prints the appropriate upgrade commands. Contributors handle source-checkout installs. Results are cached for one day.

| Option | Effect |
|---|---|
| `--json` | Print the result as JSON |
| `--app` | App bundle path, for identifying a Homebrew install |
| `--app-version` | That bundle's version |

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-11 · commit `641c3a0` · verified against code._
