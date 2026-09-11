# FAQ

## Does publication happen in CI?

**Short answer:** No. As of v0.3.0, GitHub Actions validates and builds the package, but it does
not publish it. A release is published explicitly from a clean checkout with `uv publish` and a
`UV_PUBLISH_TOKEN` in the environment, then verified from PyPI before the Git tag and GitHub
release are created.

### Sources

- [GitHub Actions check workflow](../../.github/workflows/check.yml) — runs lint, tests, build and
  distribution checks, with no publish job.
- [Release recipes](../../justfile) — defines the explicit local build and `uv publish` path.
- [v0.3.0 release](https://github.com/lucharo/voice2text/releases/tag/v0.3.0) — the first release
  completed through this path.

_Verified: 2026-08-01 · Scope: v0.3.0. Recheck the workflow and release recipes before a later
release._

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

- [Menu state rendering](../../v2t/native/Voice2Text.swift) — maps startup, ready, active and error
  states and shows why “Stop v2t” can appear before readiness.
- [Status command](../../v2t/cli.py) — reports live state, selected models, mode and launch error.
- [Smoke tests](../../tests/test_smoke.py) — verifies the `idle` status output and error-state
  behaviour.
- [README usage](../../README.md) — documents the live menu states, `v2t status`, permissions and
  the hotkey interaction.

_Created: 2026-08-29 · Updated: 2026-08-29 · Verified: 2026-08-29 · Scope/version: v0.3.0
behaviour._

## Why did the models take 45 seconds to load, and does v2t ever need the Hugging Face revision checks?

**Short answer:** The weights load in about 2 s from the local cache. The rest was Hugging Face's
revision check, one round trip per model file, which stalls on slow or SSL-intercepted networks.
Measured on hotel Wi-Fi: Parakeet 45 s → 0.5 s and the cleanup model 19 s → 1.2 s with the checks
off. v2t now turns them off whenever the model's snapshot is already in the cache, and never needs
them at that point: a dictation tool has no reason to follow upstream weight updates on a warm start.
The checks still run for a first download or a partial cache, where the network is genuinely needed.

### Sources

- [`load_cache_first`](../../v2t/backends.py) — flips `huggingface_hub.constants.HF_HUB_OFFLINE`
  around the load when `cached_locally` finds a snapshot, and retries online on failure.
- [Smoke tests](../../tests/test_smoke.py) — `test_cached_models_load_without_hub_revision_checks`
  and `test_partial_cache_falls_back_to_an_online_load`.
- [README startup time](../../README.md#startup-time) — the user-facing statement.

_Created: 2026-09-04 · Updated: 2026-09-04 · Verified: 2026-09-04 (timings measured on an M4 Pro)._

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

- [Menu app source](../../v2t/native/Voice2Text.swift) — requests microphone and accessibility, then
  launches the engine with `V2T_LAUNCH_CONTEXT=menubar`.
- [LaunchAgent](../../v2t/service.py) — `ProgramArguments` runs the app bundle, not Python.
- [README menu-bar section](../../README.md#optional-menu-bar-app) — permissions paragraph.

_Created: 2026-09-04 · Updated: 2026-09-04 · Verified: 2026-09-04 · Scope: v0.3.x on macOS 26; the
launchd-without-bundle path has not been re-tested on this macOS version._

## How do I turn streaming transcription on or off, and what does it actually change?

**Short answer:** It is on by default with the Parakeet backend: `streaming_mode = "hacky"` under
`[transcription]`, or `v2t --streaming-mode hacky`; `off` restores decoding after release. While the
hotkey is held the recogniser is fed every 5 s and the menu bar shows *Recording… N words*. Only
dictations of 60 s or more get faster: the wait after release drops from about 1.4 s median (4.7 s
p90, 111 s worst case on a 12-minute clip) to about 0.33 s, at the cost of slightly different text
(0.7% fewer words at the median, 5% at the 10th percentile). Under 60 s the recording is still
decoded whole-file on release, so the text and timing are unchanged. Cleanup latency is unchanged
either way. Whisper has no streaming path and always decodes after release.

### Sources

- [`STREAM_CHUNK_S`, `STREAM_TAKEOVER_S`](../../v2t/backends.py) — the two constants and the
  measurements that picked them.
- [`process_live`](../../v2t/app.py) — the feed loop and the 60 s takeover rule.
- [Streaming benchmark](../../utils/wisprflow_benchmarking_profiling/README.md) — `--streaming`
  reports the latency left after release and the disagreement per duration bucket.

_Created: 2026-09-08 · Verified: 2026-09-08 (208 clips, M4 Pro, PR #17)._

## Why is the streamed text not identical to whole-file decoding, when it is the same model?

**Short answer:** Same weights, different attention. Parakeet's FastConformer encoder is
bidirectional: every audio frame attends to the whole clip, so offline decoding needs all the audio
first. parakeet-mlx's `transcribe_stream` swaps that for a ±20 s local window plus a cache, and
normalises the log-mel features per push, neither of which the offline checkpoint was trained for.
That is where the drift comes from, and why the mode is called `hacky`. Push size does not change
the latency (a push costs ~0.3 s whatever its length, because the context is re-encoded each time)
but it does change accuracy: on 208 clips 1 s pushes disagreed with whole-file decoding by 0.156 of
the words at the median, 5 s pushes by 0.062. A decoder-only model such as GPT-2 has none of this:
causal attention only looks left, so generating token by token is the batch computation split in
time. A `clean` mode would use a checkpoint trained to stream (NVIDIA's `parakeet-unified` or the
cache-aware Nemotron streaming models); none is in MLX yet. Whisper's encoder is also bidirectional
over a fixed 30 s window and mlx-whisper exposes no cached path, so streaming it would mean
re-encoding the last 30 s every second.

### Sources

- [`ParakeetStream`](../../v2t/backends.py) — the wrapper around `transcribe_stream(context_size=(256, 256), depth=1)`.
- [Issue #19](https://github.com/lucharo/voice2text/issues/19) — the clean-mode candidates and the
  MLX gap.
- [Issue #12](https://github.com/lucharo/voice2text/issues/12) and
  [PR #17](https://github.com/lucharo/voice2text/pull/17) — the measurements behind the numbers.

_Created: 2026-09-08 · Verified: 2026-09-08._
