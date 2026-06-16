# Changelog

## 0.3.0

The single-file proof-of-concept is preserved at the [`nano`](https://github.com/lucharo/voice2text/releases/tag/nano) tag.
This release turns v2t into a small, modular, MLX-first package.

- **Parakeet is the default backend** (`mlx-community/parakeet-tdt-0.6b-v3`) — ~10× faster than Whisper on Apple Silicon, multilingual. Whisper stays available as the `whisper` backend.
- **Pluggable STT backends** as install extras: `voice2text[parakeet]` (default), `voice2text[whisper]`, `voice2text[all]`.
- **Pluggable cleanup engines** — default is **mlx-lm, in-process** (`Qwen3-4B-Instruct-2507`): no Ollama, no daemon, same MLX stack as transcription. Ollama stays as an optional `engine = "ollama"`. Use a non-thinking model with either.
- **Guided `v2t setup`** — pick the transcription model and cleanup engine; detects Ollama and offers it, otherwise defaults to mlx-lm. Writes `~/.v2t/config.toml`.
- **Config file** at `~/.v2t/config.toml` (honors `$V2T_HOME` / `$XDG_CONFIG_HOME`), with `v2t config [--init]`.
- **Transcription history** — every result + metadata appended to `~/.v2t/history/transcriptions.jsonl`.
- **SwiftBar plugin** (`swiftbar/v2t.5s.sh`) — menu-bar toggle, status, open config/history.
- **Benchmark harness** — `v2t bench` writes a per-machine markdown grid (STT RTF + cleanup TTFT/total) with `engine:model` columns. Self-contained STT inputs via macOS `say`.
- **New commands**: `v2t setup`, `v2t status`, `v2t stop`, `v2t config`, `v2t bench`.

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
