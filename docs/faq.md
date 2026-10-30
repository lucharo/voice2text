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
[config](reference/config.md). **From Nemotron**, under it, takes those words from a second model
made to stream (`preview = "nemotron"`): they change about every 0.6 s instead of every 1.1 s, and
the pasted text is the same.

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
and a dictionary term written in place of a word that sounds like it. LibriSpeech clean stays at 1.94%, and the extra errors fell from 1.4 to
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

Errors in this table were counted with the grid's earlier scorer (Whisper's normaliser), which
reads 0.1 to 0.9 points higher on LibriSpeech and about 2 points higher on FLEURS Spanish than the
leaderboard's scorer the grid uses now.

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

Parakeet v3 is accurate and the quickest of the accurate models. [Benchmarks](benchmarks.md) has the chart. The maintainers' grid compares
them on 450 labelled clips, 40 long recordings and 208 real dictations on an M4 Pro
([#54](https://github.com/lucharo/voice2text/pull/54), October 2026). Parakeet v3 scores 1.7 / 3.7 /
3.2% (LibriSpeech clean, LibriSpeech other, FLEURS Spanish), 1.9% on long recordings, and waits
0.1 to 0.2 s on short clips. Errors here are counted the Open ASR Leaderboard's way, so they
compare with model cards (see [below](#why-do-v2ts-error-rates-differ-from-model-cards-and-the-open-asr-leaderboard)).

- **Cohere Transcribe** is the most accurate in English: 1.3 / 2.3 / 3.5%, and 1.2% on long recordings. It
  also transcribes silence. On 5 near-silent dictations it invented about 7,000 words, so it would
  need voice detection in front of it. It has no language detection and needs about 4.8 GB of
  memory.
- **Qwen3-ASR 1.7B** (8-bit) is about as accurate on short labelled clips (1.3 / 3.7 / 3.0%) and
  makes about half the mistakes on real dictations, but waits 0.3 to 0.9 s on short clips. It is an
  opt-in backend: see [Should I switch to Qwen3-ASR?](#should-i-switch-to-qwen3-asr)
- **Whisper large-v3-turbo** matches Parakeet on short clips but waits about 1 s, and makes more
  errors on long recordings.
- **Voxtral** (4-bit, streaming) waits about 0.7 s, makes more errors on the labelled short clips,
  and disagrees more with the other models on real dictations.
- **Nemotron** (streaming) waits less (0.07 s) but makes more errors: 2.7 / 7.6 / 4.3%.
- **Parakeet Redux** and **Phonon-2** are much smaller downloads (178 MB and 164 MB) and somewhat
  less accurate. They are candidates for a phone. Phonon-2 is English only, so its published
  average covers fewer sets: on the same English clips it scores 3.2% against Parakeet v3's 2.7%.
- **Parakeet Unified EN** (English only, opt-in with `backend = "parakeet"`) makes fewer mistakes
  on most English sets: 1.5 / 2.9% on LibriSpeech, 7.8% against 8.7% on the leaderboard's AMI,
  6.7% against 7.2% on its Earnings22 and 4.7% against 5.2% on the real dictations (against
  the default, Parakeet v3 on Core ML), waiting 0.17 s against 0.13 s. Parakeet v3 stays
  the default because it also handles other languages.
- **Bark 3.0 Pro** (English only, opt-in with `backend = "parakeet-coreml"`) is a fine-tune of
  Parakeet v3 that runs on the same Core ML path. It makes fewer mistakes on noisy recordings and
  ties on read speech and real dictations, for 1.1 to 1.2 times the wait and twice the download:
  see [Should I switch to Bark 3.0 Pro?](#should-i-switch-to-bark-30-pro)
- **Noisy recordings** (added late October 2026): on AMI meetings recorded with a room microphone
  Parakeet v3 scores 33.3%, against 28.2% for Qwen3-ASR and 26.0% for Cohere; on the
  leaderboard's AMI (headsets) 8.9%, against 7.7% and 6.7%, and on its Earnings22 6.1%, against
  5.9% and 6.8%. Qwen3-ASR does not invent text on silence, unlike Cohere, which is why it, not
  Cohere, became the opt-in second backend.
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
two are within 0.02 points. These rates were counted with the grid's earlier scorer. Counted the
Open ASR Leaderboard's way on the grid's own runs, the same comparison reads 5.0% against 2.4% on
the dictations, 29.2% against 28.2% on AMI and 9.9% against 8.5% on Earnings22.

While you hold the key, v2t decodes the recording in pieces of about 30 s cut at quiet moments, so
release waits on the last piece only; there are no previews between pieces, since each would be a
full decode. A Core ML build that could cut the wait and memory is tracked in
[#64](https://github.com/lucharo/voice2text/issues/64).

## Should I switch to Bark 3.0 Pro?

If you dictate only in English and often far from the microphone, it is worth a try. Conway
Research's [Bark 3.0 Pro](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro)
(CC-BY-4.0) is a fine-tune of Parakeet v3 published in the same Core ML layout, so v2t runs it on
the Neural Engine through its default `parakeet-coreml` backend, with the same live words while
you hold the key. Pick it under Transcription Model in the menu, or:

```bash
v2t config set transcription.backend parakeet-coreml transcription.model ConwayResearch/Underdog-Bark-3.0-Pro
```

The first run downloads its Core ML files (1.23 GB), compiles them once (about 10 s) into
`~/.v2t/models/underdog-bark-3.0-pro-coreml`, deletes the download, and loads them on the Neural
Engine, which takes about a minute the first time and a few seconds after that. Run
`v2t config set transcription.model ""` to return to Parakeet v3.

Measured on the maintainers' grid on an M4 Pro (October 2026, [#79](https://github.com/lucharo/voice2text/issues/79),
[#80](https://github.com/lucharo/voice2text/issues/80)), errors counted the Open ASR Leaderboard's
way, against the default Parakeet v3 on Core ML:

| | Parakeet v3, Core ML | Bark 3.0 Pro, Core ML |
|---|--:|--:|
| AMI meetings, headset (150 clips) | 8.7% | 6.4% |
| AMI meetings, room microphone (150 clips) | 29.2% | 26.6% |
| Earnings22 phone calls (150 clips) | 9.9% | 9.2% |
| LibriSpeech clean / other (150 clips each) | 1.7% / 4.1% | 1.7% / 3.8% |
| Disagreement on 122 real dictations | 6.0% | 6.0% |
| Wait after release, against the default's | 1 | 1.1 to 1.2 |
| Download | 0.63 GB | 1.23 GB |

Over the five labelled sets it makes 1.2 points fewer mistakes on average (95% interval 0.5 to
2.0). It is English only, so Parakeet v3 stays the default. Bark writes acronyms as spaced letters
("C L I") more often than Parakeet; v2t joins those after cleanup. v2t adds 0.25 s of silence
before each recording, the setting its card was evaluated with. With the same files on 40 grid
clips (short, noisy, five-minute and real dictations), v2t's decode gives the grid's text word for
word, whole or in the pieces it decodes while you hold the key. Choosing between languages
automatically is tracked in [#94](https://github.com/lucharo/voice2text/issues/94).

## Should I switch to Nemotron-Labs Unified ASR 0.6B?

Not for the final text on a Mac, but its stream can drive the live words in the bubble. NVIDIA's
[Nemotron-Labs Unified ASR 0.6B](https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b)
decodes whole files and also streams. Offline it is a little more accurate than Parakeet v3 but
waits 1.5 to 1.6 times as long after you let go, and in English Qwen3-ASR 8-bit beats it. Its
1.12 s stream updates the bubble every 0.56 s where Parakeet's preview updated every 5 s, so v2t
offers it as the live words only (From Nemotron under Live Words in Bubble, or
`transcription.preview = "nemotron"`); the pasted text still comes from the transcription model.

Measured on the maintainers' grid on an M4 Pro through FluidAudio's Core ML build (October 2026,
[#85](https://github.com/lucharo/voice2text/issues/85)), 150 clips per set, errors counted the
Open ASR Leaderboard's way:

| | Parakeet v3, Core ML | Nemotron Unified, offline | Nemotron Unified, 1.12 s stream |
|---|--:|--:|--:|
| LibriSpeech clean / other | 1.7% / 4.1% | 1.7% / 3.4% | 1.7% / 4.1% |
| FLEURS Spanish | 3.4% | 3.4% | 5.2% |
| Earnings22 phone calls | 9.9% | 9.6% | 9.1% |
| AMI meetings, room microphone | 29.2% | 28.4% | 32.2% |
| Disagreement on 208 real dictations | 5.3% | 5.4% | 7.1% |
| Wait after release, against the default's | 1 | 1.5 to 1.6 | |
| Download | 0.63 GB | 0.63 GB (int8) | another 0.6 GB |

Pooled over the five labelled sets it makes 0.3 points fewer mistakes (95% interval 0.8 fewer to
0.2 more), which is not clear of chance. The int8 build is as accurate as fp16. On the same
dictations Qwen3-ASR 8-bit disagrees with the others on 3.8% of words. The 0.56 s stream setting is
0.7 points worse than 1.12 s for three times the compute. On an iPhone it is the better model; see
[What would v2t on an iPhone use?](#what-would-v2t-on-an-iphone-use).

## Why do v2t's error rates differ from model cards and the Open ASR Leaderboard?

Since late October 2026 they mostly do not: the maintainers' grid counts errors with the
[Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)'s own code
and runs the leaderboard's own AMI and Earnings22 sets, so a model card's number and the grid's
can be read side by side. Before that the grid read 0.1 to 0.9 points higher on LibriSpeech and
about 2 points higher on FLEURS Spanish, and its AMI was a different recording. Run on the full
test sets on an M4 Pro, Parakeet v3 (MLX, bf16) scores 1.48 / 3.14 / 3.31% on LibriSpeech clean,
LibriSpeech other and FLEURS Spanish, against 1.52 / 3.13 / 3.25% on the leaderboard.

| Model | LibriSpeech clean, published | ours | LibriSpeech other, published | ours | FLEURS Spanish, published | ours | AMI, published | ours | Earnings22, published | ours |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Parakeet v3, MLX bf16 | 1.52 | 1.7 | 3.13 | 3.7 | 3.25 | 3.2 | 9.42 | 8.9 | 5.85 | 6.1 |
| Parakeet v3, Core ML (default) | 1.52 | 1.7 | 3.13 | 4.1 | 3.25 | 3.4 | 9.42 | 8.7 | 5.85 | 7.2 |
| Parakeet Ultra (MLX conversion) | 1.41 | 1.5 | 2.98 | 4.1 | 2.72 | 2.8 | | 7.5 | | 6.0 |
| Parakeet Redux | 1.96 | 2.2 | 4.34 | 5.0 | 3.71 | 3.7 | | 8.5 | | 7.8 |
| Parakeet Unified EN | 1.63 | 1.5 | 3.11 | 2.9 | English only | | | 7.8 | | 6.7 |
| Phonon-2 | 1.73 | 1.9 | 3.92 | 4.4 | English only | | 9.32 | 9.8 | 6.96 | 7.0 |
| Bark 3.0 | 1.89 | 2.1 | 4.08 | 5.3 | English only | | 7.82 | 7.3 | 7.05 | |
| Qwen3-ASR 1.7B, 8-bit | 1.26 | 1.3 | 2.94 | 3.7 | 2.92 | 3.0 | 8.31 | 7.7 | 5.84 | 5.9 |
| Whisper large-v3 turbo | 2.13 | 1.7 | 3.71 | 3.7 | 2.73 | 2.9 | 13.88 | 13.1 | 8.09 | 9.9 |
| Cohere Transcribe | 0.97 | 1.3 | 2.05 | 2.3 | 3.26 | 3.5 | 7.02 | 6.7 | 7.88 | 6.8 |
| Voxtral Mini 4B Realtime, 4-bit | 1.62 | 2.0 | 4.94 | 5.7 | 2.80 | 3.3 | 13.34 | 11.6 | 9.31 | 10.2 |
| Nemotron 3.5 streaming | 2.83 | 2.7 | 6.79 | 7.6 | 4.23 | 4.3 | 13.43 | 13.8 | 15.30 | 13.6 |

Published: the leaderboard as of 26 October 2026, or the model's card where the leaderboard has
no row (Parakeet Ultra, Redux and Unified EN, Bark 3.0). AMI is the leaderboard's AMI-Cleaned
(each speaker's headset microphone), Earnings22 its six calls with corrected transcripts. Ours:
150 clips per set (all six calls for Earnings22), on an M4 Pro; a blank was not run.

Three things still separate the two columns:

- **Sample size.** 150 clips give an interval 1.5 to 2 points wide on LibriSpeech and 4 to 5
  points on AMI, and six calls leave Earnings22 good to 2 or 3 points either way; the grid's
  report prints each row's interval. Our LibriSpeech other sample happens to be harder than the
  full set (3.7% against 3.1% for Parakeet v3), which is why most of that column reads high. For a
  close call the grid can run a model over the full test sets (`ls-clean-full` and friends).
- **Runtime.** Core ML on the Mac adds up to 0.4 points against MLX on the short sets and about a
  point on Earnings22, the iPhone up to 0.9 on FLEURS; 8-bit Parakeet v3 and Qwen3-ASR stay within
  noise of full precision (Parakeet v3 on all of FLEURS Spanish: 3.27% against 3.31%). Parakeet
  Ultra through a third-party MLX conversion and Bark 3.0 through its own runtime both trail
  their cards on LibriSpeech other by about half a point more than Parakeet v3 trails its.
- **The room microphone.** The grid also keeps AMI on a single room microphone, which is how a
  laptop hears a meeting and which no leaderboard reports. On the same 127 segments Parakeet v3
  makes 12.1% errors on the headsets and 34.9% on the room microphone, so a card's 8% on AMI and
  the grid's 30% do not contradict each other.

How much to trust a published number when picking a model:

- **Trust the order, on one dataset from one source.** Measured against Parakeet v3 on the same
  clips, 25 of 27 published differences between models fall inside our intervals. The two that do
  not: Parakeet Ultra on LibriSpeech other (see Runtime above) and Whisper on LibriSpeech clean,
  which the leaderboard puts 0.6 points behind Parakeet and our clips do not.
- **Check which version of a dataset a number is on.** The leaderboard's AMI drops clips under
  1 s and its Earnings22 has corrected transcripts; the same Parakeet v3 scores 5.85% there,
  10.75% on the original Earnings22 transcripts (through the same code, by Moondream's card) and
  11.42% on NVIDIA's own card. An "average WER" also changes with the list of sets: Bark 3.0's
  4.94% averages seven, the leaderboard now averages eleven (6.18% for Parakeet v3).
- **Treat gaps under about half a point as ties.** That is within our sampling noise, and within
  the gap between the leaderboard's two rows for the same Parakeet v3 weights on two runtimes
  (6.08% and 6.18%).
- **Check the languages.** Phonon-2, Parakeet Unified EN and Bark 3.0 are English only; Bark makes
  12% errors on Spanish.
- **Nothing published measures dictation.** On real dictations the order changes: Qwen3-ASR makes
  about half of Parakeet v3's mistakes, and Whisper turbo, close to Parakeet on LibriSpeech, makes
  about three times as many.

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
  model files. Smaller candidates are Parakeet Redux (178 MB; 2.2 / 5.0 / 3.7%) and Phonon-2
  (164 MB, English only; 1.9 / 4.4%).
- **Cleanup:** Apple's Foundation Models.
- **Where it runs:** in the main app. An iOS custom keyboard cannot use the microphone and is
  stopped above about 60 to 70 MB of memory.

A phone would only be quicker than a Mac because it would use the Neural Engine, where v2t on a Mac
uses the GPU. The iPhone 16 Pro's GPU does 2.3 TFLOPS against 8.1 for the M4 Pro's, with about
60 GB/s of memory bandwidth against 273. Estimates from 14 October 2026, not measurements: about
150 times real time on the iPhone's Neural Engine and about 35 times on its GPU, against 77 times
for v2t on the Mac (108 times since 0.5.15).
