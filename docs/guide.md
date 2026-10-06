# Guide

## Transcribe a file

`v2t transcribe` runs the same local models over audio you already have: anything ffmpeg reads,
video included. No microphone or permissions are involved.

```bash
v2t transcribe memo.opus              # prints the transcript and copies it to the clipboard
v2t transcribe memo.opus > notes.txt  # redirected: plain text, no clipboard copy
v2t transcribe *.m4a                  # several files, each under a "# filename" heading
v2t transcribe --clean memo.opus      # add the cleanup pass
```

- Files are transcribed **word for word** by default, because cleanup rewrites and that is rarely
  what you want for someone else's voice note. `--casual` and `--strict` imply `--clean`.
- A 3½-minute voice note takes about 11 s with Parakeet on an M1 Max.
- Each result goes into your [history](#history) with the file it came from.

## Casual or strict cleanup

| What you said | Casual (default) | Strict |
|---|---|---|
| "Hey um I'll see you tomorrow at 9 actually no make it 10" | "Hey, I'll see you tomorrow at 9, actually no, make it 10." | "Hey, I'll see you tomorrow at 10." |
| "So basically I was thinking we could um you know maybe try the other approach" | "So basically, I was thinking we could maybe try the other approach." | "I was thinking we could try the other approach." |

- **Casual** adds punctuation and removes "um" and "uh", keeping your phrasing.
- **Strict** also drops false starts and restructures. With a small model it can over-edit.
- Pick per run with `v2t --strict`, or set `mode` in the [config](reference/config.md).
- `v2t --no-cleanup` pastes the raw transcription.

Either way, long dictations are cleaned in chunks of about 120 words. A chunk whose cleaned length
falls outside 75 to 130% of what you said (60 to 130% in strict) is pasted raw instead, so cleanup can
punctuate but never drop or invent content.

## History

Every dictation and file transcription is saved to `~/.v2t/history/history.sqlite`: raw and
cleaned text, timings, which microphone, how loud, and whether it worked.

```bash
v2t history                 # the last 10, oldest first, with timings
v2t history --last 3 --raw  # the raw transcription next to the cleaned one
v2t history standup         # entries that mention "standup"
v2t history --json --last 0 # every entry as JSON lines
```

- Failed dictations are saved too, so a dead microphone shows up beside the device that caused it.
- When a recording has almost no speech-level sound, v2t still pastes it but names the device and
  the level in the log, a macOS notification and `v2t status`.
- The menu app's **Copy Last Transcription** recovers a paste that landed in the wrong window.
- The last recording's audio stays at `~/.v2t/run/last-recording.wav`, so
  `v2t transcribe ~/.v2t/run/last-recording.wav` redoes a dictation that went wrong.
- `save_history = false` turns history off.

## Dictionary

Names, products and jargon that come out wrong go in `~/.v2t/dictionary.txt`, one per line.

| Line | Effect |
|---|---|
| `Parakeet` | Shown to the cleanup model, which spells similar-sounding words this way |
| `my sequel => MySQL` | Exact, case-insensitive replacement after cleanup; works with cleanup off too |

```bash
v2t dictionary                          # list
v2t dictionary add Parakeet             # add a term
v2t dictionary add "my sequel => MySQL"
v2t dictionary apply transcript.txt     # try the replacements on a transcript
v2t dictionary import-wispr             # merge Wispr Flow's dictionary, if you use it
```

`apply` reads standard input when no file is given and prints which replacements fired, so you can
test a new line against the text that prompted it.
