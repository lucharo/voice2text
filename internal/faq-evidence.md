<!-- Maintainer-only. Never built into the docs site; public pages never link here. -->

# User FAQ: sources and verification

The answers users read are in `docs/faq.md`. These are the original entries with their code sources, measurements and verification dates, including notes from the managed work Mac.

## How can I tell whether Voice2Text is still loading or healthy?

**Short answer:** “Loading transcription model…” means startup is still in progress. “Stop v2t”
only means the engine process exists; it does not prove the models are ready. The app is ready when
the menu says “Ready” or `v2t status` reports `idle`, permissions are granted, and no launch error is
shown. That confirms service-level health, but only a real hold-and-release hotkey dictation (Fn by
default) confirms end-to-end recording, transcription, cleanup and paste.

If the menu remains on a loading state, allow first-launch model loading to finish and inspect
**Log**. “Could not start — open Log” or a non-empty error field from `v2t status` is an explicit
failure. During active use, `recording`, `transcribing`, and `cleaning` are healthy working states.

### Sources

- [Menu state rendering](../v2t/native/Voice2Text.swift) — maps startup, ready, active and error
  states and shows why “Stop v2t” can appear before readiness.
- [Status command](../v2t/cli.py) — reports live state, selected models, mode and launch error.
- [Smoke tests](../tests/test_smoke.py) — verifies the `idle` status output and error-state
  behaviour.
- [Getting started](../docs/getting-started.md) and [FAQ](../docs/faq.md) — document the live menu states, `v2t status`, permissions and
  the hotkey interaction.

_Created: 2026-08-29 · Updated: 2026-08-29 · Verified: 2026-08-29 · Scope/version: v0.3.0
behaviour._

## Why did the models take 45 seconds to load, and does v2t ever need the Hugging Face revision checks?

**Short answer:** The weights load in a few seconds from the local cache (figures below). The 45 s
was Hugging Face's revision check, one round trip per model file, which stalls on slow or SSL-intercepted networks.
Measured on hotel Wi-Fi: Parakeet 45 s → 0.5 s and the cleanup model 19 s → 1.2 s with the checks
off. v2t now turns them off whenever the model's snapshot is already in the cache, and never needs
them at that point: a dictation tool has no reason to follow upstream weight updates on a warm start.
The checks still run for a first download or a partial cache, where the network is genuinely needed.

**Warm-start timings (updated 2026-10-19).** From the `parakeet ready (Ns)` and `cleanup (mlx)
ready (Ns)` lines in `~/.v2t/run/v2t.log` and `v2t.log.1` on the M4 Pro, 24 real starts from
2026-09-28 to 2026-10-15: Parakeet 1.7 s typical, 5.8 s p90, 15.6 s worst; cleanup (`Qwen3.5-2B`)
4.4 s typical, 5.3 s p90, 6.0 s worst; about 6 s a launch. A recount on 2026-10-19 found 25 starts
(Parakeet median 1.8 s, p90 6.1 s, worst 15.6 s; cleanup median 4.4 s, p90 5.5 s), the extra one
on 2026-10-15 15:27 under benchmark load, when Parakeet took 11.0 s and cleanup 23.5 s. Since
0.5.15 Parakeet is read as the 2.5 GB fp32 file and quantised to 8-bit at load
(`PARAKEET_BITS`, `_quantized()` in `v2t/backends.py`, 96547fd / #51); parakeet-mlx 0.5.2 reads
no `quantization` block, so saving an 8-bit copy (0.75 GB) would need a custom loader and is
deferred. The cleanup model's 4.4 s is the larger target.

**Core ML start-up (correction).** An earlier figure of 0.4 s for loading Core ML Parakeet
(issue #55 body, the 2026-10-15 prototype comment on #52) was wrong. Remeasured on 2026-10-19:
Core ML 3.3 to 4.9 s against 1.4 to 2.7 s for MLX. Draft #56's own run on 2026-10-15, under load
about 19, gave Core ML 2.8 to 3.8 s, MLX 8-bit 0.9 to 6.0 s and both models 4.1 to 5.4 s. The
first Neural Engine load after the model files change recompiles and took 28.8 s.

### Sources

- [`load_cache_first`](../v2t/backends.py) — flips `huggingface_hub.constants.HF_HUB_OFFLINE`
  around the load when `cached_locally` finds a snapshot, and retries online on failure.
- [Smoke tests](../tests/test_smoke.py) — `test_cached_models_load_without_hub_revision_checks`
  and `test_partial_cache_falls_back_to_an_online_load`.
- [How it works, Startup](../docs/how-it-works.md#startup) and the [FAQ](../docs/faq.md) — the
  user-facing statements.
- [PR #51](https://github.com/lucharo/voice2text/pull/51) (96547fd) — load-time quantisation,
  "quantization happens at load, ~2 s".
- [Draft PR #56](https://github.com/lucharo/voice2text/pull/56) — its Core ML load timings.

_Created: 2026-09-04 · Updated: 2026-10-19 · Verified: 2026-10-19 (log recount; timings measured
on an M4 Pro)._

## Why does the login service need the menu app? Why can't the engine just run all the time?

**Short answer:** Because macOS grants the microphone to an app identity, not to a bare process. The
engine is a Python process; started from a terminal it borrows that terminal's Microphone and
Accessibility grants, and started by `launchd` on its own it has no identity to be granted to, so
the microphone is silently denied. `Voice2Text.app` exists to be that identity: it asks for the two
permissions once, then starts and supervises one warm engine, and `v2t service install` launches the
same bundle at login so both routes share one stable grant. On a managed Mac that blocks unsigned
apps, the working alternative is a terminal window that stays open with `v2t` running; a Developer
ID-signed and notarised bundle would restore the menu route there.

### Sources

- [Menu app source](../v2t/native/Voice2Text.swift) — requests microphone and accessibility, then
  launches the engine with `V2T_LAUNCH_CONTEXT=menubar`.
- [LaunchAgent](../v2t/service.py) — `ProgramArguments` runs the app bundle, not Python.
- [Getting started, the menu app](../docs/getting-started.md#the-menu-app-optional) — permissions paragraph.

_Created: 2026-09-04 · Updated: 2026-09-04 · Verified: 2026-09-04 · Scope: v0.3.x on macOS 26; the
launchd-without-bundle path has not been re-tested on this macOS version._

## How do I change between the pill styles?

**Short answer:** Open the menu-bar waveform icon and choose **Pill**. **Near text cursor** is the
default; in an app that exposes no text caret it sits at the bottom of the focused field or pane.
**Bottom of screen** pins it there, and **Off** hides it.

The bubble sits at the caret in apps that report caret bounds through accessibility: native text
views (TextEdit, Notes, Mail, Messages, Xcode) and, since 0.5.5, Chromium and Electron fields with
text in them (Chrome, Brave, Claude, Slack), measured from the character before the caret. An empty
Chromium field reports no caret, so the pill sits just below the field. Ghostty 1.3.1 reports its
focused pane but not where the cursor is inside it (its accessibility view has no caret-bounds
call), so there the pill sits at the bottom of the pane you are typing in.

The live transcript is experimental and off by default since 0.5.5: `live_transcript = true` under
`[transcription]` in `config.toml` turns it on. Words appear about 1 s after you say them, but an
early wrong word can pull you into correcting yourself mid-sentence. Cleanup shows a live seconds
counter. Placement persists across launches. See the
[pill section of How it works](../docs/how-it-works.md#the-pill) for Esc and Undo behaviour.

### Sources

- [Native menu and pill](../v2t/native/Voice2Text.swift) — selector, defaults, caret and pane
  anchors, rendering.
- [Ghostty 1.3.1 surface view](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift)
  — accessibility overrides, none for caret bounds.
- [Streaming constants](../v2t/backends.py) — `STREAM_CHUNK_S`, `PREVIEW_STEP_S` and the
  2026-10-06 preview measurements.
- [Engine status](../v2t/app.py) and [smoke tests](../tests/test_smoke.py) — streaming capability.

_Created: 2026-10-05 · Updated: 2026-10-05 · Verified: 2026-10-05 · Scope: v0.5.0 source,
native build and automated checks; live selector interaction was not exercised in this audit._

## A dictation came out as noise. Which microphone did v2t record from, and was it live?

**Short answer:** Look at the dictation's history row: `sqlite3 ~/.v2t/history/history.sqlite
"select ts, device, audio_s, loud_frac, peak, outcome from transcriptions order by id desc limit 5"`.
`device` is the macOS default input at the moment the recording started, and `loud_frac` is the
share of the recording with speech-level sound (a real dictation reads well above 0.1; a dead
input reads about 0, often with a `peak` near 1.0 from the pop of a Bluetooth link opening). When
`loud_frac` is under 2%, v2t already told you at the time: the text was pasted, but the log, a
macOS notification and the `warning` field of `v2t status` named the device and the level. The
usual cause is a Bluetooth headset whose hands-free (HFP) microphone link another app holds, Teams
in particular. Check System Settings → Sound → Input while speaking; if the meter does not move,
pick another input there. The last recording's audio is kept at `~/.v2t/run/last-recording.wav`
for `v2t transcribe`.

### Sources

- [Level measurement](../v2t/app.py) — `audio_levels` and `level_warning` define `loud_frac`
  (100 ms frames above RMS 0.01, in runs of three or more, so a click does not count) and the 2%
  threshold; `_default_input_name` records the device.
- [History schema](../v2t/config.py) — `HISTORY_COLUMNS` lists every column, including
  `device`, `rms`, `peak`, `zero_frac`, `loud_frac`, `level_warning` and `outcome`.
- [Guide, History](../docs/guide.md#history) — the same query and the warning's three surfaces.

_Created: 2026-09-11 · Verified: 2026-09-11 (a 62 s headset recording with `loud_frac` 0.0 and a
1.0 peak at 1.6 s; the built-in microphone read as `loud_frac` above 0.9 in tests)._

## How do I get the menu app onto a Mac that has no Apple signing identity, such as a managed work laptop?

**Short answer:** Install the prebuilt one. `brew trust --tap lucharo/voice2text && brew trust --cask lucharo/voice2text/voice2text`
(Homebrew 6 refuses to load a third-party tap it has not been told to trust), then `brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git` and
`brew install --cask voice2text` put a `Voice2Text.app` signed with a Developer ID Application
certificate (team `7V3HZUL435`), notarised by Apple and stapled, into `/Applications`; Gatekeeper
accepts it with no certificate on the installing Mac. The engine is still `uv tool install
voice2text`: the shell carries no user paths and finds `~/.v2t` and that interpreter at launch,
and its menu says "v2t is not installed" with the command to run when it cannot. `v2t menubar
install` still compiles a local copy into `~/Applications` when a signing identity is available,
but refuses once the cask is installed, because two copies share one bundle ID and take each other's
permissions (see the next question). On the GSK-managed Mac the notarised cask launches and
endpoint security (defendpointd) logs no rule match for it. If endpoint security refuses the
notarised app, the block is on the publisher team, which only the
device administrator can allow-list.

### Sources

- [Release script](../scripts/release-macos.sh) — `v2t menubar build` for the portable bundle,
  then notarise, staple, verify, upload to the GitHub Release and rewrite the cask.
- [Cask](../Casks/voice2text.rb) — served straight from the GitHub Release; the repository is
  public, so no token is involved.
- [Swift shell](../v2t/native/Voice2Text.swift) — the launch-time fallback to `~/.v2t` and the
  `uv tool` interpreter when nothing is baked into Info.plist.

_Verified: 2026-09-28 · Scope: v0.4.1. Allow-listing the team on a managed Mac is outside this
repository._

## Why does the menu app ask for Microphone or Accessibility again when I already granted it?

**Short answer:** Usually because a second copy of `Voice2Text.app` exists, most often an old
`v2t menubar install` build in `~/Applications` beside the cask in `/Applications`. Both carry the
bundle ID `com.lucharo.voice2text`, and macOS keeps one grant per ID pinned to one signature, so
whichever copy asks last takes the grant from the other, and Spotlight may open either. Since
v0.4.1 the menu names a second copy with a button that bins it (or hands over to `/Applications`),
and `v2t menubar install` refuses beside the cask. After removing the extra copy, one fresh grant
sticks; **Reset Permissions** in the menu clears a grant pinned to an older signature. A single
re-prompt right after `tccutil reset` or a first install is expected. Since v0.4.1 Start also waits
for the Accessibility switch instead of failing, so you no longer press Start twice.

### Sources

- [Swift shell](../v2t/native/Voice2Text.swift) — `otherCopy`, `resolveOtherCopy`,
  `resetPermissions` and the `awaiting-accessibility` phase.
- [Menu app install](../v2t/menubar.py) — the refusal when the cask copy exists.
- The unified log shows the cause: `log show --predicate 'subsystem == "com.apple.TCC"'` prints
  `Failed to match existing code requirement` with each copy's `binary_path`.

_Verified: 2026-09-28 · Scope: v0.4.1. Diagnosed on the GSK Mac, where a 0.3.0 ad-hoc build in
`~/Applications` was taking the cask's grants._

## Where does the app icon come from?

**Short answer:** From the waveform logo in `assets/logo/` (the real waveform of the words "voice
to text", from #18). Since v0.4.1 `assets/logo/app-icon.sh` renders `logo.svg` onto the macOS icon
grid into `v2t/native/AppIcon.icns`, and the bundle build copies it into `Contents/Resources` with
`CFBundleIconFile`, so both the cask and `v2t menubar install` show it in Finder and the privacy
panes. The menu-bar glyph is a separate SF Symbol that changes with state.

### Sources

- [Logo README](../assets/logo/README.md) — how the logo and the icon are regenerated.
- [Menu app build](../v2t/menubar.py) — where the icon enters the bundle.

_Verified: 2026-09-28 · Scope: v0.4.1._

## Can I redo a dictation?

**Short answer:** Yes. `~/.v2t/run/last-recording.wav` is kept after each dictation
(`behavior.keep_last_audio`, default `true`, owner-only and overwritten each time), and `v2t
transcribe ~/.v2t/run/last-recording.wav` decodes it again. 0.5.15 removed only the second,
temporary WAV that handed short recordings to parakeet-mlx through ffmpeg.

### Sources

- [`keep_last_audio`](../v2t/config.py) and the method that writes the file in [`v2t/app.py`](../v2t/app.py).
- [Config reference](../docs/reference/config.md) and [CLI reference, transcribe](../docs/reference/cli.md#transcribe).
- [PR #51](https://github.com/lucharo/voice2text/pull/51) (96547fd): `_transcribe_whole` calls
  `stt.decode` on the array for Parakeet.

_Created: 2026-10-19 · Verified: 2026-10-19 · Scope: v0.5.15._

## Can v2t transcribe faster on a Mac?

**Short answer:** 0.5.15 decodes short dictations from the recorded array and loads Parakeet in
8-bit except `self_attn`. On 450 clips (M4 Pro, 2026-10-14, arms interleaved per clip):

| Arm | Weights in memory | WER ls-clean / ls-other / fleurs-es | Wait p50 |
|---|--:|---|--:|
| WAV round trip, bf16 (0.5.14) | 1254 MB | 2.00 / 4.21 / 5.40% | 0.166 s |
| Direct decode, bf16 | 1254 MB | 1.94 / 4.21 / 5.42% | 0.121 s |
| Direct, 8-bit except `self_attn` (0.5.15) | 867 MB | 2.03 / 4.28 / 5.40% | 0.095 s |
| Direct, 4-bit, all Linear | 479 MB | 2.29 / 4.74 / 5.67% | 0.091 s |

A rerun at 15:45 with the GPU idle (load 21 to 29 from Defender and Zscaler) gave 0.195 s for the
0.5.14 WAV path, 0.120 s direct bf16 and 0.087 s for 0.5.15. The two direct arms matched the first
run; the WAV path, which is CPU work, slowed with load. Quantising `self_attn` breaks streaming:
`transcribe_stream` rebuilds attention as an unquantised module and the quantised `scales` and
`biases` raise `Received 10 parameters not in model`. 8-bit changed the text on 45 of 450 clips.
Long dictations in 30 s pieces stay at 2.3% (`ls-long`, 2.28%).

### Sources

- [PR #51](https://github.com/lucharo/voice2text/pull/51), merged as 96547fd; its agent notes hold
  the table and the rerun.
- [`CHANGELOG.md`](../CHANGELOG.md), 0.5.15.
- `PARAKEET_BITS` and `_quantized()` in [`v2t/backends.py`](../v2t/backends.py).

_Created: 2026-10-19 · Verified: 2026-10-19 · Scope: v0.5.15._

## Does v2t use the Neural Engine?

**Short answer:** Not as of 2026-10-19. MLX uses only the GPU and CPU; the Neural Engine needs Core
ML and a converted model (FluidInference's Parakeet v3 Core ML files, used by FluidAudio). All
figures are on the M4 Pro, 450 short clips:

| Date | Run | Wait p50 | WER ls-clean / ls-other / fleurs-es | WER > 15 s |
|---|---|--:|---|--:|
| 2026-10-14 | FluidAudio int8-v2 on the ANE (Swift), loaded Mac (load 33 to 39) | 0.056 s (MLX 8-bit 0.087 s) | 2.29 / 4.51 / 6.40% | 6.49% |
| 2026-10-15 | Same, 3 rotated rounds, load 16 to 60 | 0.114 s (MLX 8-bit 0.172 s); ratio 0.71 per clip, quicker on 90% | 2.29 / 4.51 / 6.40% | 6.49% (MLX 4.94%) |
| 2026-10-15 | Core ML on the GPU, int8-v2 | 0.597 s | 2.29 / 4.55 / 6.05% | 5.83% |
| 2026-10-15 | Python prototype `ct_parakeet.py` through coremltools, interleaved, load 16 to 36 | 0.062 s (MLX 8-bit 0.101 s); quicker on 96% | 2.00 / 4.66 / 5.67% | 5.25% |
| 2026-10-15 | Draft #56 `ParakeetCoreMLSTT` against v0.5.15, 3 rounds, load 18.9 to 24.5 | 0.054 s (MLX 8-bit 0.091 s); ratio 0.64, quicker on 450 of 450 | as the prototype | – |

- **Why the errors rise over 15 s:** FluidInference converted the encoder with a fixed 15 s input
  (FluidAudio uses overlapping 15 s windows). That window is a conversion choice, not a Core ML
  limit: Core ML also takes enumerated shapes (for example 2, 5, 15 and 30 s), which usually stay
  on the ANE, and the conversion code is public in FluidInference's `mobius` repo. No upstream
  issue has been filed. The prototype and #56 cut audio at the quietest 0.1 s near every 12 s
  mark (`PieceDecoder`'s rule), which is why they score 5.25% rather than 6.49%.
- **Python is enough:** from coremltools the encoder takes 29 ms per 15 s window on the ANE and a
  decoder step 0.2 to 0.3 ms, close to Swift; the prototype's text matched FluidAudio's word for
  word on a smoke test that included a 3.5-minute recording.
- **Memory (#56, `phys_footprint`, two runs per arm):** MLX 8-bit peaks at 2650 / 2685 MB, Core ML
  alone at 341 / 336 MB, and `parakeet-coreml` at 2630 / 2073 MB, because it keeps MLX loaded for
  the live text. It is not a memory saving until the live text moves to Core ML, which is why
  Luis kept #56 a draft on 2026-10-16. Between dictations it sits 0.2 to 0.8 GB above MLX alone.
- **Start-up:** see the startup entry above (Core ML 3.3 to 4.9 s against MLX 1.4 to 2.7 s on
  2026-10-19; the 0.4 s figure is wrong).
- **Size of the gain:** FluidAudio quotes about 150 times real time against v2t's 77 times (108 times
  with #51), which read as "twice as fast"; per clip the measured saving is tens of milliseconds.
  The larger gains are power, fans and a free GPU.

### Sources

- [Issue #52](https://github.com/lucharo/voice2text/issues/52), comments of 2026-10-14 and
  2026-10-15 (the three ANE runs and the prototype).
- [Issue #55](https://github.com/lucharo/voice2text/issues/55) (the opt-in backend proposal).
- [Draft PR #56](https://github.com/lucharo/voice2text/pull/56), agent notes (grid row, interleaved
  timing, peak memory, load). Not merged; revalidate this entry when it lands.

_Created: 2026-10-19 · Verified: 2026-10-19 against #52, #55 and #56 · Scope: v0.5.15, #56 draft._

## Why does v2t use Parakeet v3 and not Cohere, Qwen3-ASR, Whisper or Voxtral?

**Short answer:** In the grid report of 2026-10-15 (`~/.v2t/eval/grid/2026-10-15-report.md`,
private; the systems were added in #54), WER on ls-clean / ls-other / fleurs-es and p50 offline
wait:

| System | WER | Wait p50 (ls-clean) | ls-long | Notes |
|---|---|--:|--:|---|
| parakeet-v3 (bf16 reference) | 1.9 / 4.2 / 5.4% | 0.14 s | 2.3% (30 s pieces) | Ships; 0.5.15's 8-bit is quicker |
| cohere-transcribe | 1.4 / 2.7 / 4.9% | 0.18 s | 1.5% | Peak about 4.8 GB; 29% `wispr` disagreement |
| qwen3-asr-1.7b-8bit | 1.6 / 4.2 / 5.0% | 0.35 s | 2.1% whole, 2.2% chunked | `wispr` p50 1.65 s whole |
| whisper-turbo | 1.8 / 4.5 / 5.0% | 1.48 s | 5.0% whole, 2.7% chunked | |
| voxtral-rt-4bit | 2.5 / 6.4 / 5.4% | 0.70 s | 2.2% | 17.1% `wispr` disagreement |
| nemotron-3.5-stream | 3.1 / 8.3 / 8.8% | 0.07 s | 4.2% | |
| parakeet-redux | 2.5 / 5.5 / 5.7% | 0.10 s | 3.0% chunked | 178 MB download |
| phonon-2 | 2.3 / 5.0 / – | 0.05 s | 4.3% whole | 164 MB, English only |

Cohere Transcribe has no language detection and transcribes silence, as its model card warns. On 5
`wispr` dictations (17 to 803 s) where every other system and Wispr's own ASR heard almost nothing,
it invented about 7,000 words of repeated text, which is its whole 29%. It would need voice
detection in front of it. `wispr` has no ground truth: its percentages are disagreement with the
other systems' consensus, not errors. The ls-long and `wispr` waits come from the loaded 2026-10-14 run and
read 15 to 30% high; the short-set waits were rerun on a quieter Mac on 2026-10-15.

### Sources

- [PR #54](https://github.com/lucharo/voice2text/pull/54), merged as 2affc82, and
  [`utils/asr_grid/README.md`](../utils/asr_grid/README.md).
- The report and `2026-10-15-pareto.png` stay under `~/.v2t/eval/grid/`; cite #54, not the files.

_Created: 2026-10-19 · Verified: 2026-10-19 against the 2026-10-15 report._

## Which Macs were the benchmarks run on?

**Short answer:** The ASR grid (#54, #51, #56) ran on an M4 Pro with 48 GB. The `just bench`
rows in [`benchmarks/results/GRID.md`](../benchmarks/results/GRID.md) come from an M1 Pro
(2026-06-16) and an M1 Max (2026-07-24) and time `say` clips only, which every model transcribes at
about 0 to 2% WER, so they say nothing about accuracy.

_Created: 2026-10-19 · Verified: 2026-10-19._

## What would v2t on an iPhone use?

**Short answer:** Proposed, not measured. FluidAudio running Parakeet v3 through Core ML on the
Neural Engine, plus Apple Foundation Models for cleanup, with transcription in the main app: an
iOS custom keyboard cannot record and is capped at roughly 60 to 70 MB. FluidAudio's Core ML files
come to about 600 MB (#55). Phone candidates from the grid: Parakeet Redux (178 MB download,
2.5 / 5.5 / 5.7%) and Phonon-2 (164 MB, English only, 2.3 / 5.0%); FluidAudio lists Core ML builds
of them at about 220 MB and 360 MB (#52).

**Estimate (2026-10-14, not measured).** Parakeet v3 needs roughly 15 GFLOP per second of audio.
M4 Pro GPU 8.1 TFLOPS FP32 and 273 GB/s; iPhone 16 Pro GPU 2.3 TFLOPS and about 60 GB/s. Working
back from the Mac and Argmax's figure (iPhone 16 Pro ANE 4.3 times faster than its GPU for
Parakeet v3): ANE about 150 times real time, GPU about 35 times, against v2t's 77 times (108 times
with #51). Per #52, a 10 s dictation would take 0.06 to 0.1 s on the ANE and 0.3 to 0.4 s on the
GPU, against 0.12 s measured on the Mac GPU. A phone would be quicker only because it would use the
ANE; its GPU is slower than the Mac's.

### Sources

- [Issue #52](https://github.com/lucharo/voice2text/issues/52) (estimate table, references to
  FluidAudio, Argmax and KeyboardKit).
- [`utils/asr_grid/README.md`](../utils/asr_grid/README.md) (phone-candidate rows).

_Created: 2026-10-19 · Unresolved until #52 has iPhone timings._
