# How it works

## One dictation, start to finish

1. **Record.** The microphone opens when you press the key.
2. **Transcribe.** Parakeet turns the audio into text, on the GPU, while you are still talking.
3. **Clean up.** A small local LLM (`Qwen3.5-2B` by default) adds punctuation and drops the
   "um"s. It may not add or remove content: a chunk whose length drifts too far is pasted raw.
4. **Paste.** The text goes in at your cursor, and your previous clipboard is put back.

Both models stay loaded between dictations, so each one starts at once.

## What happens while you hold the key

- **Under 60 seconds:** every 5 seconds the new audio goes to Parakeet, which keeps a running
  draft for the menu bar. When you let go, the whole recording is transcribed in one pass: about
  a third of a second, and the most accurate text.
- **From 60 seconds:** the draft stops, and the recording is transcribed whole in pieces of about
  30 seconds while you keep talking. Each piece ends at the quietest moment near its mark, so no
  word is cut in half. When you let go only the last piece is left: about 0.2 s, however long you
  spoke.
- The live transcript on the pill is experimental and off. With `live_transcript = true` under
  `[transcription]`, v2t also previews the newest audio every second, so words appear about 1 s
  after you say them. The preview is for display only and never changes the pasted text.

![Wait after letting go of the key, by dictation length: reading the whole file grows from 0.1 s to about 20 s; in pieces it stays between 0.05 and 0.6 s from 60 s up](images/wait-vs-length.svg)

<small>One dot per dictation, Parakeet v3 on an M4 Pro.</small>

Transcribing the whole recording on release would take longer the longer you spoke: 1.3 s at the
median for dictations over a minute, and 9 to 19 s for ones of ten minutes or more. Until 0.5.8
v2t kept the running draft instead. That was quick, but each stretch of audio was transcribed using
only the ~20 seconds before it. On 40 recordings of one to five minutes with known text, pieces got
2.3% of words wrong against 5.3% for the draft.

`v2t --streaming-mode off` (or `streaming_mode = "off"`) turns this off: nothing is transcribed
until you let go, and every recording is transcribed whole. Whisper cannot stream, so it always
works that way.

## The pill

With the [menu app](getting-started.md#the-menu-app-optional), a small speech bubble sits up and to
the right of the caret while you dictate, its tail curling down-left to just above it, so it covers
neither the caret nor the text beside it. Near the top of the screen it sits down and to the right
instead. It never takes focus, so the paste lands where you were typing.

| State | The pill shows |
|---|---|
| Recording | A waveform of the level v2t is really capturing; a flat line means the microphone is silent |
| Transcribing | A ripple |
| Cleaning up | A pulse, with a seconds counter |

- **Pill** in the menu picks where it sits: **Near text cursor** (the default), **Bottom of
  screen**, or **Off**.
- The tail finds the caret in native text views (TextEdit, Notes, Mail), and in Chrome, Brave and
  Electron apps such as Slack once the field has text; an empty Chromium field reports no caret, so
  the tail points at the field's start. In a tall pane with no caret, such as a Ghostty split, the
  pill sits at the bottom of the pane.
- After Esc, the cancelled pill shows an **Undo ⌘Z** chip for 5 s. The chip, Cmd+Z or **Undo Cancel** in the menu brings the
  dictation back and carries on recording; after 5 s the audio is dropped and Cmd+Z goes to the app
  as usual.

## Startup

- Both models load from the local cache in about 2 s.
- v2t never asks Hugging Face for updates once a model is cached, so a slow or blocked network
  cannot stall startup. Only the first download needs a connection.
