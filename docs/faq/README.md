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
shown. That confirms service-level health, but only a real hold-and-release Right Command dictation
confirms end-to-end recording, transcription, cleanup and paste.

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
  Right Command interaction.

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
