# Changelog

## 0.3.0

The single-file proof-of-concept is preserved at the [`nano`](https://github.com/lucharo/voice2text/releases/tag/nano) tag.
This release turns v2t into a small, modular, MLX-first package.

- **Parakeet is the default backend** (`mlx-community/parakeet-tdt-0.6b-v3`) — ~10× faster than Whisper on Apple Silicon, multilingual. Ships in core, so `uv tool install voice2text` just works.
- **Pluggable STT backends** — Whisper is an optional alternative: `uv tool install 'voice2text[whisper]'`, then select it in config.
- **Pluggable cleanup engines** — default is **mlx-lm, in-process** (`Qwen3-4B-Instruct-2507`): no Ollama, no daemon, same MLX stack as transcription. Ollama stays as an optional `engine = "ollama"`. Use a non-thinking model with either.
- **Guided `v2t setup`** — pick the transcription model and cleanup engine; detects Ollama and offers it, otherwise defaults to mlx-lm. Writes `~/.v2t/config.toml`.
- **Config file** at `~/.v2t/config.toml` (honors `$V2T_HOME` / `$XDG_CONFIG_HOME`), with `v2t config [--init]`.
- **Transcription history** — every result + metadata appended to `~/.v2t/history/transcriptions.jsonl`.
- **Optional one-file menu-bar app** — native permission identity, immediate state, Start/Stop, and config/history/log links without a window or Xcode project.
- **Optional LaunchAgent** — `v2t service install` starts the same menu app at login and keeps one warm Python engine.
- **Reliable runtime lifecycle** — single-instance locking, honest live states, microphone failure recovery, native permission checks, and safe shutdown while a transcription finishes.
- **Private, lossless local data** — config/history/status use owner-only permissions, temporary audio is always removed, logs no longer include dictated text, and rich clipboard contents survive paste.
- **Reproducible install and release path** — constrained scientific dependencies, bundled Swift source, clean sdists, smoke-test CI, and validated build/release commands.
- **Contributor benchmark harness** — `just bench` writes a per-machine markdown grid (STT RTF + cleanup TTFT/total) with `engine:model` columns. Optional Whisper stays in the dev dependency group.
- **New commands**: `v2t setup`, `v2t status`, `v2t stop`, `v2t service`, `v2t config`, `v2t menubar`.

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
