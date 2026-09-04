# Changelog

## Unreleased

- **Microphone permission works on first run.** When the startup check has just been granted Microphone access, `v2t` restarts itself once so CoreAudio initialises with the grant, instead of failing every push-to-talk until a manual restart (#7). The microphone error now says to restart if the grant is fresh.
- **Menu app signing prefers Developer ID.** `v2t menubar install` signs `Voice2Text.app` with a Developer ID Application identity when the keychain has one (hardened runtime with the audio-input entitlement, secure timestamp), falling back to Apple Development.
- **Warm starts no longer wait for the network.** Models already in the Hugging Face cache load with hub revision checks off (45 s → 0.5 s for Parakeet, 19 s → 1.2 s for the cleanup model on hotel Wi-Fi); a partial cache still falls back to an online load.
- **`v2t dictionary`** — `~/.v2t/dictionary.txt` holds names and jargon the cleanup model must spell exactly, plus `heard => written` replacements applied after cleanup. `v2t dictionary import-wispr` merges Wispr Flow's dictionary from its local database. The menu app links to the file.
- **Casual is the default cleanup mode.** Measured over 206 real dictations, strict mode with the 1.5B model kept a median 72% of the words: it was summarising. Casual only punctuates and drops fillers. `--strict` remains available.
- **Cleanup is chunked and length-guarded.** Long transcripts are cleaned in sentence-aligned chunks of ~120 words; any chunk whose cleaned length leaves 75–130% of the raw chunk (60–130% in strict) or hits its token limit is pasted raw, and the log says how many. No more looping on long dictations.
- **Double-tap for hands-free recording.** Two quick taps of the hotkey latch the recorder on; the next tap stops it and transcribes. Holding still works. A single short tap is ignored.
- **Cleanup prompt rebuilt as system prompt + worked examples** — three (raw, clean) demonstrations per mode are sent as prior turns, and the rules now say the dictation is text to clean, never a message to answer. Same contract for both engines: mlx-lm renders the chat template with `enable_thinking=False` (safe for hybrid Qwen3 models, ignored by others) and Ollama uses `/api/chat` at temperature 0.
- **`v2t history`** — read the JSONL back: last N entries with timings, `v2t history <term>` searches raw and clean text, `--raw` shows both, `--json` re-emits records for `jq`.
- **Menu-bar app refresh** — bold state row with its symbol, models in small secondary type, SF Symbol icons on every action, green/orange permission dots, a red status icon while recording, and a *Last transcription* preview with **Copy Last Transcription**.
- **Qwen3.5 as the documented quality upgrade** — `mlx-community/Qwen3.5-4B-4bit` (non-thinking by default) replaces Qwen3-4B in the benchmark defaults and the README; the shipped default stays Qwen2.5-1.5B. Benchmark cleanup samples no longer overlap the few-shot examples.

## 0.3.0

The single-file proof-of-concept is preserved at the [`nano`](https://github.com/lucharo/voice2text/releases/tag/nano) tag.
This release turns v2t into a small, modular, MLX-first package.

- **Parakeet is the default backend** (`mlx-community/parakeet-tdt-0.6b-v3`) — ~10× faster than Whisper on Apple Silicon, multilingual. Ships in core, so `uv tool install voice2text` just works.
- **Pluggable STT backends** — Whisper is an optional alternative: `uv tool install 'voice2text[whisper]'`, then select it in config.
- **Pluggable cleanup engines** — default is **mlx-lm, in-process** (`Qwen2.5-1.5B-Instruct`): no Ollama, no daemon, same MLX stack as transcription. Ollama stays as an optional `engine = "ollama"`. Use a non-thinking model with either.
- **Lower idle memory and faster cleanup** — the default cleanup model drops from 4B to the locally validated 1.5B model, and paste timing now appears in logs/history.
- **Native menu icon** — the menu uses adaptive SF Symbols instead of emoji for off, loading, ready, recording, processing, and error states.
- **Guided `v2t setup`** — pick the transcription model and cleanup engine; detects Ollama and offers it, otherwise defaults to mlx-lm. Writes `~/.v2t/config.toml`.
- **Config file** at `~/.v2t/config.toml` (honors `$V2T_HOME` / `$XDG_CONFIG_HOME`), with `v2t config [--init]`.
- **Transcription history** — every result + metadata appended to `~/.v2t/history/transcriptions.jsonl`.
- **Optional one-file menu-bar app** — native permission identity, immediate state, Start/Stop, and config/history/log links without a window or Xcode project.
- **Optional LaunchAgent** — `v2t service install` starts the same menu app at login and keeps one warm Python engine.
- **Reliable runtime lifecycle** — single-instance locking, honest live states, microphone failure recovery, native permission checks, and safe shutdown while a transcription finishes.
- **Private, lossless local data** — config/history/status use owner-only permissions, temporary audio is always removed, logs no longer include dictated text, and rich clipboard contents survive paste.
- **Reproducible install and release path** — constrained scientific dependencies, bundled Swift source, clean sdists, smoke-test CI, and validated build/release commands.
- **Contributor benchmark harness** — `just bench` writes a per-machine markdown grid (STT RTF + cleanup TTFT/total) with `engine:model` columns. Optional Whisper stays in the dev dependency group.
- **Transcribe files you already have** — `v2t transcribe memo.opus [more…]` runs the configured backend over anything ffmpeg reads, prints the transcript to stdout and copies it to the clipboard when interactive. Verbatim by default (`--clean` / `--casual` / `--strict` opt into the LLM pass), with live elapsed time per step and a realtime-factor summary. Results land in the same history JSONL as dictations, tagged with their `source` file.
- **New commands**: `v2t transcribe`, `v2t setup`, `v2t status`, `v2t stop`, `v2t service`, `v2t config`, `v2t menubar`.

## 0.2.0

- Warm up both Whisper and Ollama models at startup so the first transcription is fast
- Show model load times during startup

## 0.1.1

- Fix `--pause-music` starting music when nothing was playing
- Fix `uvx` command: use `--from voice2text v2t`
- Add GPL v2 license, macOS-only note
- README improvements and badges

## 0.1.0

- Initial release
- Push-to-talk with Right Command key
- Local Whisper transcription via mlx-whisper
- LLM cleanup with Ollama (qwen2.5:3b)
- Strict and casual modes
- `--pause-music` flag for media control
- Clipboard-based paste at cursor
