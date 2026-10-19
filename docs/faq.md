# FAQ

## Is v2t still loading, or is it ready?

- **Ready:** the menu says **Ready**, or `v2t status` starts with `idle`.
- **Still loading:** the menu says "Loading transcription model…", or `v2t status` says
  `loading-stt` or `loading-cleanup`. The first launch downloads the models, so it takes longer.
- **Failed:** the menu says "Could not start — open Log", or `v2t status` says `launch-error` with
  the reason.

**Stop v2t** in the menu only means the engine process exists, not that it is ready. A real
dictation is the only end-to-end proof.

## Why does the menu app exist? Can't the engine just run on its own?

macOS gives the microphone to an app, not to a bare process. Started from a terminal, the engine
borrows that terminal's permissions; started on its own at login, it has none, and the microphone
is silently denied. `Voice2Text.app` is the app that holds the two permissions and starts the
engine, and `v2t service install` launches that same app at login.

## A dictation came out as nonsense. Which microphone did it use?

Look at the last few entries in the history:

```bash
sqlite3 ~/.v2t/history/history.sqlite \
  "select ts, device, audio_s, loud_frac, outcome from transcriptions order by id desc limit 5"
```

- `device` is the macOS input at the moment you started.
- `loud_frac` is the share of the recording with speech-level sound. A real dictation is well above
  0.1; a dead input is about 0.
- Below 2%, v2t already warned you at the time, in the log, a notification and `v2t status`.

The usual cause is a Bluetooth headset whose microphone another app (often Teams) is holding. Speak
and watch System Settings → Sound → Input; if the meter does not move, pick another input there.
The audio is still at `~/.v2t/run/last-recording.wav` for `v2t transcribe`.

## Can I redo a dictation?

Yes. v2t keeps the last recording at `~/.v2t/run/last-recording.wav`, replaced by each new one, so
you can transcribe it again:

```bash
v2t transcribe ~/.v2t/run/last-recording.wav
```

The setting is `behavior.keep_last_audio`, on by default (see the [config reference](reference/config.md)).
**Settings** in the menu turns it on or off. Since 0.5.15, v2t no longer writes a second temporary
WAV to hand the audio to Parakeet; the kept recording is unchanged.

## How do I move the pill or hide it?

Open the menu-bar icon and choose **Pill**:

- **Near text cursor**: the default. A speech bubble up and to the right of the caret, its tail
  pointing at it; in a Ghostty split, at the bottom of the pane.
- **Bottom of screen**: always there.
- **Off**: no pill.

The choice persists across launches. The live transcript is experimental and off; **Settings →
Live Words in Bubble** turns it on, as does `live_transcript = true` under `[transcription]` in the
[config](reference/config.md).

## Why is the pill at the bottom of the screen instead of at my cursor?

Near text cursor puts the bubble at the caret of the focused text field. With no field focused, as
after clicking plain text on a page or a button, there is no caret, so the pill sits at the bottom
of the screen; it also sits at the bottom of a pane in a terminal such as Ghostty, which does not report its caret.
Slack, browsers and other Chromium or Firefox apps build what the pill reads about 2 s after v2t
asks, so the first dictation in a freshly opened app can start at the bottom and move to the caret.
Each time the pill appears or moves, `~/.v2t/run/v2t.log` records the app, the focused element's
role and how the caret was found (`caret`, `marker`, `no-caret`, `no-text`).

## The pill stopped showing at all. What happened?

Most likely it is showing on another desktop. After the menu app had run for about a day, its pill
window was once found pinned to Desktop 1, so on any other desktop or over a full-screen app it
never appeared. The log gives it away: each `pill shown` line in `~/.v2t/run/v2t.log` ends with
`on active space false`. Since 0.5.13 the pill rebuilds itself when that happens, and the log says
`pill rebuilt`. On an older version, quit the menu app and open it again. Restarting the Mac or
reinstalling is not needed.

## Can I install the menu app on a managed work Mac?

Yes. The Homebrew app is signed with a Developer ID certificate, notarised by Apple and stapled, so
macOS accepts it with no signing certificate on your Mac. Install it as in
[Getting started](getting-started.md#the-menu-app-optional). If your company's endpoint security
still blocks it, only your device administrator can allow it.

## Why does the menu app keep asking for Microphone or Accessibility?

Almost always because there are two copies of `Voice2Text.app`, usually an old `v2t menubar
install` build in `~/Applications` beside the Homebrew one in `/Applications`. macOS keeps one
permission per app identity, so the copy that asked last takes it from the other.

- The menu names a second copy and offers a button to remove it.
- After removing it, grant the permissions once more; **Reset Permissions** in the menu clears an
  old grant.
- One prompt right after a fresh install is expected.

## How long does cleanup take?

About half a second at the median with the default `Qwen3.5-2B`, and nine in ten finish within
about 2 s, measured on 201 real dictations on an M4 Pro.

- Since 0.5.0 the fixed part of the prompt is processed once and reused, and the model checks
  several guessed words per step: the median went from 1.27 s to 0.51 s.
- For more speed, use `Qwen3.5-0.8B` ([cleanup models](reference/config.md#cleanup-models)) or
  `v2t --no-cleanup`.

## Why do the models take a few seconds to load at startup?

v2t reads both models from disk and prepares them before the first dictation. Across 24 real
starts on an M4 Pro (28 September to 15 October 2026):

- **Parakeet**, the speech model: 1.7 s typical, 5.8 s for nine starts in ten, 15.6 s at worst.
- **Cleanup** (`Qwen3.5-2B`): 4.4 s typical.

That comes to about 6 s before the menu says **Ready**. Parakeet arrives as one 2.5 GB file, and
since 0.5.15 v2t converts it to 8-bit each time it loads. Saving an 8-bit copy (0.75 GB) would
make loading quicker; that is not done yet. Once the models are cached, startup never waits on the
network ([How it works](how-it-works.md#startup)).

## Can v2t transcribe faster on a Mac?

It already got faster in 0.5.15 ([#51](https://github.com/lucharo/voice2text/pull/51)). The median
wait after you let go on short dictations fell from 0.166 s to about 0.09 s on an M4 Pro, from two
changes:

- Short dictations go from the recorded audio straight to Parakeet, without a temporary WAV and
  ffmpeg.
- Parakeet loads in 8-bit except its attention layers. It takes 867 MB of memory instead of
  1254 MB and decodes about 30% faster.

Errors barely moved: 2.03 / 4.28 / 5.40% against 1.94 / 4.21 / 5.42% on 450 labelled clips
(LibriSpeech clean, LibriSpeech other, FLEURS Spanish). Two other options were tried and dropped.
Attention in 8-bit broke the live transcript, and 4-bit was 0.3 to 0.5 points worse and no faster.
The download stays 2.5 GB because the conversion happens at load. The next possible step is the
Neural Engine (below).

## Does v2t use the Neural Engine?

Not yet (19 October 2026). v2t runs Parakeet through MLX, which uses only the GPU and CPU. The
Neural Engine is reachable only through Core ML, with a converted model such as the Parakeet v3
that [FluidAudio](https://github.com/FluidInference/FluidAudio) ships.

Measured on an M4 Pro, 450 labelled clips, the two run alternately clip by clip:

| Date | Comparison | Median wait | Errors |
|---|---|--:|---|
| 15 Oct 2026 | FluidAudio on the Neural Engine against MLX 8-bit, 3 rounds | 0.114 s against 0.172 s, quicker on 90% of clips | 6.5% against 4.9% on dictations over 15 s |
| 15 Oct 2026 | Draft [#56](https://github.com/lucharo/voice2text/pull/56) against 0.5.15, 3 rounds | 0.054 s against 0.091 s, quicker on every clip | 5.25% against 4.94% over 15 s |

FluidAudio's model decodes in fixed 15 s windows, which is where its extra errors on longer
dictations come from. Draft #56 cuts long audio at quiet moments instead. It adds a
`parakeet-coreml` backend, off by default, that uses Core ML for the final text and keeps MLX for
the live transcript. That has costs today:

- **Memory:** no saving yet. Core ML alone peaked at about 0.34 GB, but #56 also loads MLX, so its
  peak equals MLX's, about 2.6 GB.
- **Start-up:** Core ML took 3.3 to 4.9 s to load against 1.4 to 2.7 s for MLX (19 October 2026).

The saving is tens of milliseconds a dictation. Power, fan noise and a free GPU are the larger
gains. #56 stays a draft until the live transcript also runs on Core ML, and
[#55](https://github.com/lucharo/voice2text/issues/55) tracks the work.

## Why does v2t use Parakeet v3 and not Cohere, Qwen3-ASR, Whisper or Voxtral?

Parakeet v3 is accurate and the quickest of the accurate models. The maintainers' grid compares
them on 450 labelled clips, 40 long recordings and 208 real dictations on an M4 Pro
([#54](https://github.com/lucharo/voice2text/pull/54), October 2026). Parakeet v3 scores 1.9 / 4.2 /
5.4% (LibriSpeech clean, LibriSpeech other, FLEURS Spanish), 2.3% on long recordings, and waits
0.1 to 0.2 s on short clips.

- **Cohere Transcribe** is the most accurate: 1.4 / 2.7 / 4.9%, and 1.5% on long recordings. It
  also transcribes silence. On 5 near-silent dictations it invented about 7,000 words, so it would
  need voice detection in front of it. It has no language detection and needs about 4.8 GB of
  memory.
- **Qwen3-ASR 1.7B** (8-bit) is about as accurate on short clips (1.6 / 4.2 / 5.0%) but waits 0.3
  to 0.6 s on them and 1.6 s (median) on real dictations.
- **Whisper large-v3-turbo** matches Parakeet on short clips but waits about 1 s, and makes more
  errors on long recordings.
- **Voxtral** (4-bit, streaming) waits about 0.7 s and makes more errors on short clips and real
  dictations.
- **Nemotron** (streaming) waits less (0.07 s) but makes far more errors: 3.1 / 8.3 / 8.8%.
- **Parakeet Redux** and **Phonon-2** are much smaller downloads (178 MB and 164 MB) and somewhat
  less accurate. They are candidates for a phone.

## Which Macs were the benchmarks run on?

- **The speech-model grid** (accuracy and wait, the numbers in the entries above): an M4 Pro with
  48 GB.
- **`just bench`** (an M1 Pro and an M1 Max): times synthetic clips made with macOS `say` and
  measures no accuracy.

The per-Mac `just bench` rows are in
[GRID.md](https://github.com/lucharo/voice2text/blob/main/benchmarks/results/GRID.md). Timings
depend on the Mac, so compare models on the same machine.

## What would v2t on an iPhone use?

This is a proposal; nothing has been measured on an iPhone yet.
[#52](https://github.com/lucharo/voice2text/issues/52) tracks a real test on an iPhone 16 Pro.

- **Speech:** FluidAudio running Parakeet v3 through Core ML on the Neural Engine, about 600 MB of
  model files. Smaller candidates are Parakeet Redux (178 MB; 2.5 / 5.5 / 5.7%) and Phonon-2
  (164 MB, English only; 2.3 / 5.0%).
- **Cleanup:** Apple's Foundation Models.
- **Where it runs:** in the main app. An iOS custom keyboard cannot use the microphone and is
  stopped above about 60 to 70 MB of memory.

A phone would only be quicker than a Mac because it would use the Neural Engine, where v2t on a Mac
uses the GPU. The iPhone 16 Pro's GPU does 2.3 TFLOPS against 8.1 for the M4 Pro's, with about
60 GB/s of memory bandwidth against 273. Estimates from 14 October 2026, not measurements: about
150 times real time on the iPhone's Neural Engine and about 35 times on its GPU, against 77 times
for v2t on the Mac (108 times since 0.5.15).
