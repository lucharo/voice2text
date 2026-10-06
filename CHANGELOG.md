# Changelog

## 0.5.7

- **The pill sits up and to the right of the caret**, its tail curling down-left at 45° to just above it, so it no longer covers the caret or the text beside it. Without room above, it sits down and to the right instead. An empty field gets the same placement from its start.

## 0.5.6

- **The pill is a speech bubble beside the text box you're typing in**, with a Messages-style tail pointing at the caret, or at the start of an empty field. It sits below the box when the box is in the top half of the screen and above it otherwise. Tall panes without a caret (a Ghostty split) keep the pill at the bottom of the pane.
- **Undo is easier to see and use.** The pill's Undo is a visible chip labelled ⌘Z, and **Cmd+Z** brings the cancelled dictation back. The cancelled pill and its undo go away after 5 s, and the held audio is dropped then. Cmd+Z goes to the app as usual at any other time.
- **Opening the app starts v2t** once Microphone and Accessibility are granted, so there's no Start click after a login, an upgrade or a relaunch.

## 0.5.5

- **The live transcript is parked as experimental.** It is off, and the menu toggle is gone. Set `live_transcript = true` under `[transcription]` in `config.toml` to bring it back. While it is off the engine runs no previews.
- **The pill counts the cleanup up live in seconds**, so you can see how quick it is each time.
- **In Chrome, Brave and Electron apps such as Claude and Slack, the pill now follows the caret** once the field has text. It is measured from the character before the caret, because Chromium reports no height for the empty caret position. Electron apps are asked to build their accessibility tree (`AXManualAccessibility`).
- The menu shows the installed version under the model line, and **Send Feedback…** opens a new GitHub issue.
- Releases publish on the `v<version>` tag push alone; the manual approval step in the `release` environment is gone (only `v*` tags may deploy to it).

## 0.5.4

- **The live transcript keeps up: words show about 1 s after you say them, down from about 3 s.** Between 5 s decoding chunks the engine previews the newest audio every second. The preview is display only: the pasted text is unchanged (identical with and without previews on 7 recordings).
- **In apps that expose no text caret, such as Ghostty, the pill sits at the bottom of the pane you are typing in** rather than the bottom of the screen.
- The Pill menu reads **Near text cursor**, **Bottom of screen** and **Off**, without the A/B labels left over from the design comparison.

## 0.5.3

- Publish the notarised Mac app when GitHub Actions has checked out an annotated release tag as a local lightweight tag. Verify the remote commit without rewriting the checkout's tag.

## 0.5.2

- Keep the Mac app's version aligned with the Python package. Includes the 0.5.0 desktop UI and 0.5.1 publication fix.

## 0.5.1

- Fix Mac release publication after notarisation: zsh now passes the existing release tag's refspec unchanged to Git. This completes delivery of the 0.5.0 desktop UI; dictation behaviour is unchanged.

## 0.5.0

- **Cleanup is about 2.5× faster.** Each cleanup call used to run the whole prompt (instructions, worked examples and dictionary terms, about 775 tokens) through the model and then write one token per model step. Now the fixed part of the prompt is processed once and reused, and the model guesses its next words from the dictation, checking up to eight in one step and keeping only those it agrees with. Over 201 real dictations on an M4 Pro the median cleanup went from 1.27 s to 0.51 s and p90 from 5.34 s to 2.09 s. The text is identical on 169 of them; the other 32 differ by about three words, from float rounding when the prompt is processed in two parts.
- **A floating pill shows the dictation while it happens.** B appears beside the text insertion caret by default; A sits at the bottom of the screen and is the automatic fallback when an app exposes no caret. The calmer waveform scrolls with captured input, travels during transcription and pulses during cleanup, without status words. **Pill → Show live transcript** optionally adds streamed words, off by default and enabled only when the engine supports streaming. Placement and transcript visibility persist across launches. The pill never takes focus, so the paste still lands where you were typing.
- **Esc cancels without pasting; Undo recovers the recording.** Cancelling during recording, transcription or cleanup discards late results. Undo on the pill or menu recovers the captured audio and resumes hands-free recording; press Fn to finish.

## 0.4.1

- **Releases publish from GitHub Actions.** A `v<version>` tag push, once approved in the `release` environment, uploads the engine to PyPI (trusted publishing) and the notarised menu app to the GitHub Release, and commits the cask; `scripts/ci-signing-secrets.sh` loads the Developer ID certificate and notary key into that environment once.
- **One copy of the menu app owns the permissions.** An older `v2t menubar install` build left in `~/Applications` shares the cask's bundle ID, and macOS keeps one Microphone and one Accessibility grant per ID pinned to one signature, so each copy revoked the other's grants and a relaunch from Spotlight could open the stale one. The menu now names a second copy with a button: from `/Applications` it moves the other to the Bin; from the stray copy it bins that copy (only if it is the `~/Applications` install) and opens the `/Applications` one. `v2t menubar install` refuses when the cask is installed.
- **Start waits for Accessibility instead of failing.** Before, pressing Start with Accessibility off opened the prompt and went straight to "Permissions required", so the user had to come back and press Start again. Now the menu shows "Turn on Voice2Text under Accessibility" and starts the engine within a second of the switch going on, with Cancel Start beside it. When a grant still reads as missing, **Reset Permissions** clears the app's Microphone and Accessibility decisions (`tccutil reset`) and asks again, which clears a grant left pinned to an older build's signature.
- **The menu app has the waveform logo as its icon.** `Voice2Text.app` shipped with the generic app icon in Finder, `/Applications` and the Microphone and Accessibility panes; it now carries `AppIcon.icns`, rendered from `assets/logo/logo.svg` by `assets/logo/app-icon.sh`. The menu-bar glyph is unchanged.

## 0.4.0

- **The menu app ships prebuilt, signed and notarised.** `brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git` then `brew install --cask voice2text` installs a Developer ID-signed, notarised `Voice2Text.app` into `/Applications`, so a Mac with no Apple signing identity (a managed work laptop) gets the same stable permission identity as a local build. The bundle carries no user paths: it finds `~/.v2t` and the `uv tool install voice2text` interpreter at launch, and the menu says "v2t is not installed" with the one command to run when it cannot. `v2t menubar build DIR` compiles that portable bundle; `scripts/release-macos.sh --publish` (`just release-macos --publish`) signs, notarises, staples, uploads it to the GitHub Release and rewrites `Casks/voice2text.rb`. `v2t menubar install` is unchanged, and `v2t menubar open` and the login service prefer the `/Applications` copy when both exist.
- **History is a SQLite database, and it knows which microphone.** `~/.v2t/history/history.sqlite` holds one row per dictation or file transcription (table `transcriptions`): raw and cleaned text, models and timings, the trigger (hold, latched, file), the input device the recording came from, its level (`rms`, `peak`, `zero_frac`, `loud_frac`), cleanup chunk stats, dictionary replacements fired, and the outcome, with failed dictations recorded too. A pre-existing `transcriptions.jsonl` is imported on first open (and topped up from any lines an older, still-running v2t appends afterwards) and left in place; `v2t history` reads the database. A dictation with almost no speech-level sound is still pasted, but the log, a macOS notification and the `warning` field of `v2t status` name the device and the level, which is how a Bluetooth headset whose link never opened shows itself.
- **Fn is the hotkey, and a short press leaves no trace.** `key = "fn"` (the 🌐 key, bottom-left) is the default; Right Command and the other modifiers remain choices under `[hotkey]`. The microphone still opens on the press so no speech is lost, but the recording only becomes visible (status, log, music pause, streaming) once the key has been down for 0.5 s: a shorter tap is dropped silently, and a press joined by another key before then (Fn+arrow, Cmd+Enter) is a chord, dropped at once and never counted towards a double-tap. `v2t` warns at startup when System Settings still gives the 🌐 key to the emoji picker (change it in the Keyboard pane; the `defaults` write alone does not apply to running apps).
- **Cleanup writes numbers as digits and puts `#` before PR and issue numbers.** "PR three five nine closes issue forty two, version zero point one" comes out as "PR #359 closes issue #42, version 0.1"; both modes carry the rule and a worked example (#23).
- **Transcription runs while the hotkey is held.** With the Parakeet backend the recording is fed to the recogniser in 5 s pushes as it happens; the log and the menu-bar tooltip show how many words it has heard so far. From 60 s of audio up the streamed text is taken on release, so only the last push is left to decode (~0.3 s on an M4 Pro) instead of ~11 ms per second of audio; shorter recordings are still decoded whole-file, which costs about the same there and keeps their text exactly as before. The mode is called `hacky` because it runs the offline model with a local-attention window it was not trained for; `v2t --streaming-mode off` (or `streaming_mode = "off"` under `[transcription]`) turns it off, and a `clean` mode on a streaming-trained checkpoint is tracked separately. Whisper has no streaming path and is unchanged (#12).
- **Recording follows the current microphone.** PortAudio's device list is re-read before every recording, so switching input in System Settings, plugging or unplugging a headset, or a Bluetooth profile change during a call no longer leaves `v2t` recording from the old device or failing with `Invalid Property Value` until restart (#14).
- **Qwen3.5-2B is the default cleanup model.** On 208 real dictations in casual mode it kept 98% of the words (p10 93%) at 1.17 s median, against 92% at 0.85 s for Qwen2.5-1.5B, 96% at 0.61 s for Qwen3.5-0.8B and 96% at 2.21 s for Qwen3.5-4B. The 0.8B is the documented fast option; `just bench` compares all three by default.
- **Microphone permission works on first run.** When the startup check has just been granted Microphone access, `v2t` restarts itself once so CoreAudio initialises with the grant, instead of failing every push-to-talk until a manual restart (#7). The microphone error now says to restart if the grant is fresh.
- **Menu app signing prefers Developer ID.** `v2t menubar install` signs `Voice2Text.app` with a Developer ID Application identity when the keychain has one (hardened runtime with the audio-input entitlement, secure timestamp), falling back to Apple Development.
- **Warm starts no longer wait for the network.** Models already in the Hugging Face cache load with hub revision checks off (45 s → 0.5 s for Parakeet, 19 s → 1.2 s for the cleanup model on hotel Wi-Fi); a partial cache still falls back to an online load.
- **`v2t dictionary`** — `~/.v2t/dictionary.txt` holds names and jargon the cleanup model must spell exactly, plus `heard => written` replacements applied after cleanup. `v2t dictionary import-wispr` merges Wispr Flow's dictionary from its local database. The menu app links to the file. `v2t dictionary apply <file>` runs the replacements over a transcript (stdin when no file) and reports on stderr which entries fired, so a new `heard => written` line can be proven before the next dictation.
- **Casual is the default cleanup mode.** Measured over 206 real dictations, strict mode with the 1.5B model kept a median 72% of the words: it was summarising. Casual only punctuates and drops fillers. `--strict` remains available.
- **Cleanup is chunked and length-guarded.** Long transcripts are cleaned in sentence-aligned chunks of ~120 words; any chunk whose cleaned length leaves 75–130% of the raw chunk (60–130% in strict) or hits its token limit is pasted raw, and the log says how many. No more looping on long dictations.
- **Double-tap for hands-free recording.** Two quick taps of the hotkey latch the recorder on; the next tap stops it and transcribes. Holding still works. A single short tap is ignored.
- **Cleanup prompt rebuilt as system prompt + worked examples** — three (raw, clean) demonstrations per mode are sent as prior turns, and the rules now say the dictation is text to clean, never a message to answer. Same contract for both engines: mlx-lm renders the chat template with `enable_thinking=False` (safe for hybrid Qwen3 models, ignored by others) and Ollama uses `/api/chat` at temperature 0.
- **`v2t history`** — read the JSONL back: last N entries with timings, `v2t history <term>` searches raw and clean text, `--raw` shows both, `--json` re-emits records for `jq`.
- **Menu-bar app refresh** — bold state row with its symbol, models in small secondary type, SF Symbol icons on every action, green/orange permission dots, a red status icon while recording, and a *Last transcription* preview with **Copy Last Transcription**.
- **Benchmark cleanup samples no longer overlap the few-shot examples**, and the `just bench` cleanup columns follow the measured defaults above.

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
