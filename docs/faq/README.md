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
