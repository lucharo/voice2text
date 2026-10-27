# config.toml

## Where things live

Everything is in `~/.v2t/`, or `$V2T_HOME`, or `$XDG_CONFIG_HOME/v2t`, in that order of preference.

| Path | Holds |
|---|---|
| `config.toml` | Your settings; `v2t config --init` writes a commented one |
| `dictionary.txt` | Your [dictionary](../guide.md#dictionary) |
| `history/history.sqlite` | Every transcription, one row each |
| `run/` | The engine's status and log |
| `run/last-recording.wav` | The last dictation's audio, replaced each time |

## Keys

Every key is optional; these are the defaults. The menu app's **Settings** submenu switches
streaming, live words, cleanup, its mode, the hotkey, history and the kept recording: each switch
rewrites that one line here and restarts the engine after the dictation in progress. Edit the rest
by hand, or with `v2t config set section.key value`.

```toml
[transcription]
backend = "parakeet-coreml"
model = ""
streaming_mode = "hacky"
live_transcript = false

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

| Key | Values | Does |
|---|---|---|
| `transcription.backend` | `parakeet-coreml`, `parakeet`, `whisper`, `qwen3-asr` | Transcription engine. `parakeet-coreml` (default) runs Parakeet v3 on the Neural Engine through Core ML, with no MLX: the live text while you hold the key and the final text both come from it. The first run downloads its Core ML files (about 0.63 GB) from `FluidInference/parakeet-tdt-0.6b-v3-coreml`, or reads FluidAudio's copy in `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` when there is one. `parakeet` runs Parakeet on the GPU through MLX; `whisper` needs `voice2text[whisper]`. `qwen3-asr` runs Qwen3-ASR 1.7B (8-bit) through mlx-audio and needs `voice2text[qwen]`: it makes about half the mistakes on long and noisy dictations and waits longer, see [Should I switch to Qwen3-ASR?](../faq.md#should-i-switch-to-qwen3-asr). The first run downloads its 2.5 GB of weights |
| `transcription.model` | repo id, or a folder for `parakeet-coreml` | Blank means the Core ML files above, `parakeet-tdt-0.6b-v3`, `whisper-large-v3-turbo` or `Qwen3-ASR-1.7B-8bit`. If you speak English, `littlebearlabs/parakeet-unified-en-0.6b-mlx` with `backend = "parakeet"` (Parakeet Unified, English only) makes fewer mistakes |
| `transcription.streaming_mode` | `hacky`, `off` | Transcribe while the key is held; see [How it works](../how-it-works.md#what-happens-while-you-hold-the-key) |
| `transcription.live_transcript` | `true`, `false` | Experimental: show the words on the pill while you speak (streaming only) |
| `cleanup.enabled` | `true`, `false` | Run the cleanup model at all |
| `cleanup.engine` | `mlx`, `ollama` | In-process MLX, or a running Ollama |
| `cleanup.model` | repo id or Ollama tag | Blank means `Qwen3.5-2B-4bit` or `qwen3:4b-instruct-2507` |
| `cleanup.mode` | `casual`, `strict` | See [casual or strict](../guide.md#casual-or-strict-cleanup) |
| `hotkey.key` | `fn`, `cmd_r`, `cmd_l`, `alt_r`, `alt_l`, `ctrl_r`, `ctrl_l` | The push-to-talk key |
| `audio.sample_rate` | Hz | Recording rate |
| `behavior.pause_music` | `true`, `false` | Pause media while recording (needs `nowplaying-cli`) |
| `behavior.save_history` | `true`, `false` | Keep the [history](../guide.md#history) |
| `behavior.keep_last_audio` | `true`, `false` | Keep `run/last-recording.wav` |
| `ollama.url` | URL | Where Ollama listens |

## Cleanup models

Cleanup runs in-process through [mlx-lm](https://github.com/ml-explore/mlx-lm): no daemon, no
HTTP. Measured on 208 real dictations in casual mode on an M4 Pro:

| Model | Words kept (median / worst 10%) | Note |
|---|--:|---|
| `Qwen3.5-0.8B-4bit` | 96% / 86% | Fastest, about half the time of the default |
| `Qwen2.5-1.5B-Instruct-4bit` | 92% / 82% | The previous default |
| **`Qwen3.5-2B-4bit`** | **98% / 93%** | The default; about 0.5 s per dictation at the median |
| `Qwen3.5-4B-4bit` | 96% / 90% | Slower and no more faithful |

Any `mlx-community/…` model works; it downloads on the next launch. Use a model that does not
emit `<think>` blocks, or its reasoning gets pasted.

Already running [Ollama](https://ollama.com)? `v2t setup` offers to switch when it finds it, or:

```toml
[cleanup]
engine = "ollama"
model = "qwen3:4b-instruct-2507"
```

Then `ollama pull qwen3:4b-instruct-2507`.
