# CLI

Every verb, with its flags as `v2t <verb> --help` prints them.

| Verb | Does |
|---|---|
| [`v2t`](#v2t) | Run push-to-talk |
| [`transcribe`](#transcribe) | Transcribe audio files |
| [`history`](#history) | Show or search past transcriptions |
| [`dictionary`](#dictionary) | Manage `~/.v2t/dictionary.txt` |
| [`setup`](#setup) | Guided config: pick models, detect Ollama |
| [`status`](#status) | Print the engine's state |
| [`stop`](#stop) | Stop a running engine |
| [`config`](#config) | Show the resolved config and paths |
| [`menubar`](#menubar) | Install or open the menu app |
| [`service`](#service) | Start the menu app at login |

## v2t

```bash
v2t --strict
```

| Flag | Values | Does |
|---|---|---|
| `--config` | path | Use this `config.toml` |
| `--backend` | `parakeet`, `whisper` | Transcription backend for this run |
| `--model` | repo id | Transcription model for this run |
| `--cleanup-engine` | `mlx`, `ollama` | Cleanup engine for this run |
| `--cleanup-model` | repo id or Ollama tag | Cleanup model for this run |
| `--no-cleanup` | | Paste the raw transcription |
| `--casual` | | Punctuation and fillers only (the default) |
| `--strict` | | Also restructure and drop false starts |
| `--pause-music` | | Pause media while recording (needs `nowplaying-cli`) |
| `--streaming-mode` | `hacky`, `off` | Transcribe while the key is held (`hacky`, the default) or only after release |

## transcribe

```bash
v2t transcribe memo.opus
```

| Flag | Values | Does |
|---|---|---|
| `AUDIO …` | paths | Files to transcribe; anything ffmpeg reads |
| `--config` | path | Use this `config.toml` |
| `--backend` | `parakeet`, `whisper` | Transcription backend |
| `--model` | repo id | Transcription model |
| `--clean` | | Run the cleanup pass (off by default for files) |
| `--casual` | | Light cleanup; implies `--clean` |
| `--strict` | | Cleanup that restructures; implies `--clean` |

## history

```bash
v2t history standup --raw
```

| Flag | Values | Does |
|---|---|---|
| `term` | text | Only entries whose raw or cleaned text contains this |
| `--last`, `-n` | number | How many recent entries (default 10; `0` for all) |
| `--raw` | | Also show the raw transcription |
| `--json` | | Print the entries as JSON lines |

## dictionary

```bash
v2t dictionary add "my sequel => MySQL"
```

| Subcommand | Does |
|---|---|
| `show` | List terms and replacements (the default) |
| `add` | Add a term, or a `heard => written` replacement |
| `apply` | Run the replacements over a transcript (file or standard input) and say which fired |
| `import-wispr` | Merge Wispr Flow's dictionary from its local database |

## setup

```bash
v2t setup
```

Asks which models to use, detects Ollama, and writes `~/.v2t/config.toml`. It needs a terminal; `v2t config --init` writes the defaults without asking.

## status

```bash
v2t status
```

Prints one tab-separated line: the state, the transcription model, the cleanup model, the cleanup
mode, any launch error, and any warning about the last dictation (a silent microphone, say).

| State | Means |
|---|---|
| `off` | No engine is running |
| `loading-stt`, `loading-cleanup` | Starting: loading the transcription or cleanup model |
| `idle` | Loaded and ready |
| `recording`, `transcribing`, `cleaning`, `delivering` | Working on a dictation; `delivering` is the paste |
| `cancelled`, `stopping` | A dictation was cancelled, or the engine is shutting down |
| `launch-error` | The last start failed; the error field says why |

## stop

| Flag | Does |
|---|---|
| `--force` | Kill the engine at once instead of asking it to stop |

## config

| Flag | Does |
|---|---|
| `--init` | Write a commented `config.toml` if there is none |
| `--path` | Print the paths only |

## menubar

| Argument | Does |
|---|---|
| `install` | Compile the menu app on this Mac into `~/Applications` and open it |
| `open` | Open the installed menu app |
| `build` | Build a portable bundle for a release (maintainers) |
| `--identity` | `build` only: the code-signing identity |

Most people install the prebuilt app with Homebrew instead; see
[Getting started](../getting-started.md#the-menu-app-optional). `install` refuses when the Homebrew
copy is present, because two copies fight over the same permissions.

## service

```bash
v2t service install
```

| Subcommand | Does |
|---|---|
| `install` | Add a login item that starts the menu app, and start it |
| `start`, `stop` | Start or stop it now |
| `status` | Show whether it is loaded |
| `uninstall` | Remove the login item |
