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

## Does cleanup make the transcript more accurate?

No: at best it leaves your words as you said them. Cleanup reads only the text, so it cannot fix a
word the speech model misheard; the maintainers score it separately from transcription, on 1,800
labelled clips. Until the release after 0.5.16, casual cleanup dropped small words, changed tenses
and added words, so on LibriSpeech clean it raised Parakeet v3's errors from 1.94% to 2.19%. It now
undoes any word it dropped, changed or added, except fillers, repeats, numbers written as digits
and your dictionary terms. LibriSpeech clean stays at 1.94%, and the extra errors fell from 1.4 to
1.7 points to 0.5 to 0.7 on AMI meetings, and from 0.65 to 0.9 to 0.1 to 0.4 on Earnings22 calls
(27 October 2026). What remains is mostly repeats such as "the the", which those references keep.

## Why do the models take a few seconds to load at startup?

v2t reads both models from disk and prepares them before the first dictation. Across 24 real
starts on an M4 Pro (28 September to 15 October 2026):

- **Parakeet**, the speech model: 1.7 s typical, 5.8 s for nine starts in ten, 15.6 s at worst.
- **Cleanup** (`Qwen3.5-2B`): 4.4 s typical.

That comes to about 6 s before the menu says **Ready**. These starts used Parakeet on MLX, now
`backend = "parakeet"`, which arrives as one 2.5 GB file converted to 8-bit at each load. The
default since the release after 0.5.16 runs Parakeet on the Neural Engine instead: it downloads
0.63 GB once, then loads in 0.1 to 0.3 s plus 1.3 to 1.6 s to import coremltools
([Neural Engine](#does-v2t-use-the-neural-engine)); real starts with it have not been timed yet.
Once the models are cached, startup never waits on the network
([How it works](how-it-works.md#startup)).

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
The download stays 2.5 GB because the conversion happens at load. The next step, Parakeet on the
Neural Engine, is the default since the release after 0.5.16 (below).

## Does v2t use the Neural Engine?

Yes, by default since the release after 0.5.16 (opt-in in 0.5.16). The Neural Engine is reachable
only through Core ML, with a converted model such as the Parakeet v3 that
[FluidAudio](https://github.com/FluidInference/FluidAudio) ships, and v2t runs that model with no
MLX at all. The first run downloads the four Core ML files it needs (about 0.63 GB), or reads
FluidAudio's copy when there is one. `backend = "parakeet"` goes back to Parakeet on MLX, which uses
the GPU and CPU ([#59](https://github.com/lucharo/voice2text/issues/59)).

Measured on an M4 Pro, each pair run alternately clip by clip:

| Date | Comparison | Median wait or time | Errors |
|---|---|--:|---|
| 15 Oct 2026 | FluidAudio on the Neural Engine against MLX 8-bit, 450 clips, 3 rounds | 0.114 s against 0.172 s, quicker on 90% of clips | 6.5% against 4.9% on dictations over 15 s |
| 15 Oct 2026 | `parakeet-coreml` against 0.5.15, 450 short clips, 3 rounds | 0.054 s against 0.091 s, quicker on every clip | 2.00 / 4.66 / 5.67% against 2.03 / 4.28 / 5.40% |
| 19 Oct 2026 | Same, 40 recordings of 1 to 5 minutes, whole transcription | 0.88 s against 1.36 s, quicker on every one | 2.45% against 2.28% |
| 19 Oct 2026 | Same, 40 real dictations replayed with the live transcript on | 0.058 s against 0.29 s after release | – |

FluidAudio's model decodes in fixed 15 s windows, which is where its extra errors on longer
dictations come from. `parakeet-coreml` cuts audio at quiet moments instead, into pieces of up to
15 s, and decodes them while you speak, so release waits only for the last piece.

- **Memory:** about 0.34 GB at its peak, against about 2.6 GB for MLX 8-bit.
- **Start-up:** the models load in 0.1 to 0.3 s once compiled, and `import coremltools` takes
  1.3 to 1.6 s. On a fresh install it took 5.0 to 5.2 s, because it imported transformers and
  scikit-learn for model conversion v2t never does; v2t now hides them during the import
  (27 October 2026). That is about what MLX takes to load (1.4 to 2.7 s). The very first run
  downloads the four files and compiles them for the Neural Engine: 102 s on a fresh install,
  ready at once the next time.
- **Errors:** up to 0.4 points higher than MLX 8-bit on LibriSpeech other, FLEURS Spanish and long
  recordings, but lower on noisy ones: about 20% against 22% averaged over AMI meetings on a room
  microphone and Earnings22 phone calls.

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
- **Qwen3-ASR 1.7B** (8-bit) is about as accurate on short labelled clips (1.6 / 4.2 / 5.0%) and
  makes about half the mistakes on real dictations, but waits 0.3 to 0.9 s on short clips. It is an
  opt-in backend: see [Should I switch to Qwen3-ASR?](#should-i-switch-to-qwen3-asr)
- **Whisper large-v3-turbo** matches Parakeet on short clips but waits about 1 s, and makes more
  errors on long recordings.
- **Voxtral** (4-bit, streaming) waits about 0.7 s, makes more errors on the labelled short clips,
  and disagrees more with the other models on real dictations.
- **Nemotron** (streaming) waits less (0.07 s) but makes far more errors: 3.1 / 8.3 / 8.8%.
- **Parakeet Redux** and **Phonon-2** are much smaller downloads (178 MB and 164 MB) and somewhat
  less accurate. They are candidates for a phone. Phonon-2 is English only, so its published
  average covers fewer sets: on the same English clips it scores 3.65% against Parakeet v3's 3.07%.
- **Parakeet Unified EN** (English only, opt-in with `backend = "parakeet"`) makes fewer mistakes
  on every English set: 1.6 / 3.6% on LibriSpeech, 8.3% against 10.8% on Earnings22 phone calls
  and 5.2% against 6.0% on the real dictations, waiting 0.17 s against 0.13 s. Parakeet v3 stays
  the default because it also handles other languages.
- **Noisy recordings** (added late October 2026): on AMI meetings recorded with a room microphone
  Parakeet v3 scores 33.3%, against 28.4% for Qwen3-ASR and 25.5% for Cohere; on Earnings22 it
  scores 10.8%, against 8.6% and 9.2%. Qwen3-ASR does not invent text on silence, unlike Cohere,
  which is why it, not Cohere, became the opt-in second backend.
- **Voxtral 3**, Mistral's October 2026 transcription models, are available only through its API;
  the newest open Voxtral is Voxtral Mini 4B Realtime.

## Should I switch to Qwen3-ASR?

If waiting under a second after you let go does not bother you, probably: on real dictations it
makes about half the mistakes. Install the extra and set the backend:

```bash
uv tool install 'voice2text[qwen]'
v2t config set transcription.backend qwen3-asr
```

Measured through v2t's own `qwen3-asr` backend on an M4 Pro (October 2026, other work keeping the
load average around 45, so the waits are on the slow side), against the default Parakeet v3 on
Core ML:

| | Parakeet v3, Core ML | Qwen3-ASR 1.7B, 8-bit |
|---|--:|--:|
| Words wrong, 208 real dictations | 5.6% | 2.9% |
| ...the 162 marked against Wispr Flow's text | 5.6% | 3.0% |
| AMI meetings, room microphone (150 clips) | 29.5% | 29.0% |
| Earnings22 phone calls (150 clips, grid) | 10.3% | 8.6% |
| Wait after release, median (p90), real dictations | 0.13 s (0.26 s) | 0.77 s (1.24 s) |
| ...under 15 s | | 0.38 s |
| Memory at peak | 0.34 GB | about 3.7 GB |
| Download | 0.63 GB | 2.5 GB |

The dictations have no hand-made transcript, so each is marked against a silver one: the
transcript that Wispr Flow, Cohere Transcribe and Qwen3-ASR (bf16) agree with most. Qwen3-ASR
being one of those three flatters it, so the table also gives the score on the 162 clips whose
silver text is Wispr Flow's; the gap barely moves. On AMI the newer mlx-audio v2t installs (0.6.2)
scores 29.0%, against 28.4% for the 0.5.7 the grid used, on the same audio; on the dictations the
two are within 0.02 points.

While you hold the key, v2t decodes the recording in pieces of about 30 s cut at quiet moments, so
release waits on the last piece only; there are no previews between pieces, since each would be a
full decode. A Core ML build that could cut the wait and memory is tracked in
[#64](https://github.com/lucharo/voice2text/issues/64).

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
