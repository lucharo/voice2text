# config.toml

## Where things live

The data directory is `$V2T_HOME`, `$XDG_CONFIG_HOME/v2t` or `~/.v2t`, in that order. `V2T_CONFIG` or `v2t --config PATH` selects another configuration file.

| Path, relative to the data directory | Contents |
|---|---|
| `config.toml` | Settings; `v2t config --init` writes a commented default |
| `dictionary.txt` | Terms and [replacements](../guide.md#dictionary) |
| `history/history.sqlite` | Raw and cleaned text with timings |
| `run/v2t.log` | Log |
| `run/last-recording.wav` | Latest kept recording, replaced each time |

## Keys

All keys are optional. File settings override the defaults below; command-line options override the file.

```toml
[transcription]
backend = "parakeet-coreml"
model = ""
live_transcript = false
preview = "backend"
preview_language = "auto"

[cleanup]
enabled = true
engine = "mlx"
model = ""
mode = "casual"

[hotkey]
key = "fn"

[audio]
sample_rate = 16000

[behavior]
pause_music = false
save_history = true
keep_last_audio = true

[ollama]
url = "http://localhost:11434"
```

| Key | Values | Effect |
|---|---|---|
| `transcription.backend` | See [backends](#transcription-backends) | Choose the speech engine |
| `transcription.model` | Model ID; Core ML also accepts a folder | Blank uses the backend's default |
| `transcription.live_transcript` | Boolean | Experimental live words in the dictation bubble |
| `transcription.preview` | `backend`, `nemotron` | Source of preview words; does not change final text |
| `transcription.preview_language` | `auto` or a code listed below | Language hint for the Nemotron preview |
| `cleanup.enabled` | Boolean | Enable the cleanup model |
| `cleanup.engine` | `mlx`, `ollama` | Local in-process MLX or an Ollama server |
| `cleanup.model` | Model ID or Ollama tag | Blank uses the engine's default |
| `cleanup.mode` | `casual`, `strict` | [Cleanup behaviour](../guide.md#casual-or-strict-cleanup) |
| `hotkey.key` | `fn`, `cmd_r`, `cmd_l`, `alt_r`, `alt_l`, `ctrl_r`, `ctrl_l` | Dictation key |
| `audio.sample_rate` | Positive integer in Hz | Recording sample rate |
| `behavior.pause_music` | Boolean | Pause media; requires `nowplaying-cli` |
| `behavior.save_history` | Boolean | Save [transcription history](../guide.md#history) |
| `behavior.keep_last_audio` | Boolean | Keep the latest recording |
| `ollama.url` | URL | Ollama endpoint |

The menu's **Settings**, **Transcription Model** and **Cleanup Model** choices update their corresponding settings. For other changes, use `v2t config set SECTION.KEY VALUE` and restart the engine.

??? note "Preview language codes"

    `auto`, `en`, `es`, `fr`, `de`, `ru`, `pt`, `it`, `nl`, `pl`, `uk`, `ro`, `el`, `cs`, `hu`, `sv`, `da`, `fi`, `sk`, `hr`, `bg`, `lt`, `et`, `lv`, `sl`, `mt`.

## Transcription backends

| Backend | Default model | Install |
|---|---|---|
| `parakeet-coreml` | `FluidInference/parakeet-tdt-0.6b-v3-coreml`, Neural Engine | Included |
| `parakeet` | `mlx-community/parakeet-tdt-0.6b-v3`, MLX on the GPU | Included |
| `whisper` | `mlx-community/whisper-large-v3-turbo` | `uv tool install --python 3.13 'voice2text[whisper]'` |
| `qwen3-asr` | `mlx-community/Qwen3-ASR-1.7B-8bit` | `uv tool install --python 3.13 'voice2text[qwen]'` |

Core ML also supports the English-only `ConwayResearch/Underdog-Bark-3.0-Pro` model. See [benchmarks](../benchmarks.md) before switching models.

## Cleanup models

The MLX default is `mlx-community/Qwen3.5-0.8B-4bit`. The Ollama default is `qwen3:4b-instruct-2507-q4_K_M`; download it with `ollama pull qwen3:4b-instruct-2507-q4_K_M` before use.

The default MLX pipeline runs locally. Choosing Ollama sends transcript text to the configured `ollama.url`.

[Benchmarks](../benchmarks.md) keeps cleanup-model results separate from transcription results.

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-05 · commit `4d5dcb4` · verified against code._
