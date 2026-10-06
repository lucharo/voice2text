<!-- Maintainer-only. Never built into the docs site; public pages never link here. -->

# Releasing: records

The steps are on the public maintainer page (`docs/maintainers/index.md`). This file keeps how each release actually went, and the fallbacks.

## Does publication happen in CI?

**Short answer:** The `release.yml` workflow now handles publication after a `v<version>` tag
push, with no manual approval step (the `release` environment accepts only `v*` tags, since 2026-10-06). It publishes the engine to PyPI, then signs,
notarises and publishes the Mac app and updates the Homebrew cask.

**Correction (2026-09-28):** the earlier answer said CI only validates and builds. Version 0.4.1
adds a publication workflow, but that release was published from the personal Mac. Before the
next CI release, register the PyPI trusted publisher for owner `lucharo`, repository `voice2text`,
workflow `release.yml`, environment `release`; signing secrets are already configured. A
successful `check` run proves validation, not publication.

**Update (2026-10-05):** the publisher is now registered and read back in PyPI for exactly
`lucharo/voice2text`, `release.yml`, environment `release`. CI retains its distributions and
publishes them with publisher attestations. Registration proves configuration; the tagged
workflow and indexed artifacts must still be verified for each release.

**Verified release (2026-10-06):** [v0.5.3](https://github.com/lucharo/voice2text/releases/tag/v0.5.3)
was published by [GitHub Actions](https://github.com/lucharo/voice2text/actions/runs/37451102357).
Both indexed PyPI distributions match the CI artifacts, their publisher attestations verify,
and isolated wheel and sdist installs run `v2t --help`. The downloaded arm64 Mac app reports
0.5.3, passes signature, stapling and Gatekeeper checks, and its ZIP checksum matches the
automatically updated cask. Installation and real dictation on the work Mac remain separate checks.

### Sources

- [Release workflow](../.github/workflows/release.yml) — tag trigger, protected jobs and publication.
- [Check workflow](../.github/workflows/check.yml) — validation only.
- [v0.4.1 release](https://github.com/lucharo/voice2text/releases/tag/v0.4.1) — the local-release exception.

_Created: 2026-08-01 · Updated: 2026-10-06 · Verified: 2026-10-06 · Scope: v0.5.3 CI publication.
Recheck the tagged workflow and indexed artifacts for publication evidence._

## What does PyPI's 503 mean, and what do we need to do?

**Short answer:** The requested service is unavailable; check the failing endpoint as well as
the status page. During the 0.4.1 release, publisher settings failed while package uploads and
downloads worked. An operational component label did not prove the logged-in settings page worked.
Retry publisher setup after recovery; changing Apple signing credentials cannot fix that page.

### Sources

- [PyPI incident, 2026-09-28](https://status.python.org/incidents/krn0mpxz5jp2) — search, login and logged-in page failures.
- [Python infrastructure status](https://status.python.org/) — current incident and component state.
- [v0.4.1 release](https://github.com/lucharo/voice2text/releases/tag/v0.4.1) — publication completed through the local path.

_Created: 2026-09-28 · Updated: 2026-09-28 · Verified: 2026-09-28 · Scope: the 0.4.1 incident;
test the actual endpoint again before treating a later error as the same outage._

## Can we release from the Mac when CI setup is blocked?

**Short answer:** Yes, with publication authorised and the release source fixed to a clean commit.
Publish and verify the engine first, then use the signed Mac app release path in the
[release script](../scripts/release-macos.sh). The script without `--publish` only builds,
signs, notarises and verifies; GitHub publication and the cask update remain outstanding.

For 0.4.1, signing failed with `errSecInternalComponent` in the agent's background session but
succeeded when the user ran the same build in a normal terminal. After that handoff, we published
the verified ZIP from its recorded source commit, checked the downloaded bytes and Gatekeeper
acceptance, and committed the cask checksum. The duplicate tag-triggered CI publication was cancelled.

### Sources

- [Release script](../scripts/release-macos.sh) — verification and optional publication gates.
- [v0.4.1 release](https://github.com/lucharo/voice2text/releases/tag/v0.4.1) — source commit and notarised ZIP.
- [Cask update](https://github.com/lucharo/voice2text/commit/84f65026a6d590c98902a7cee6734129fb7f2e70) — published version and checksum.

_Created: 2026-09-28 · Updated: 2026-09-28 · Verified: 2026-09-28 · Scope: v0.4.1 on the personal Mac;
the terminal workaround is an observed result, not a diagnosis of every signing error._

## Menu app signing, as the README described it before the docs site

Both routes produce the same bundle, signed with hardened runtime plus the audio-input
entitlement. The cask ships a build signed with a `Developer ID Application` certificate and
notarised by Apple, which is what a Mac with no signing identity of its own needs; it carries no
user paths and finds `~/.v2t` and the `uv tool install voice2text` interpreter at launch, and its
menu says "v2t is not installed" with the one command to run when it cannot. `v2t menubar install`
compiles the same source on this Mac with the best identity in the keychain (Developer ID, then
Apple Development, then ad-hoc). Keep only one: both copies share a bundle ID, and macOS pins each
permission grant to one signature, so whichever copy asks last takes the other's grants. `v2t menubar
install` refuses once the cask is installed, and the menu names any second copy with a button that
bins it (or, from the stray copy, hands over to `/Applications`). Releasing is pushing a `v<version>` tag that matches
`pyproject.toml`: `.github/workflows/release.yml` (no manual approval step; only `v*` tags reach the `release` environment)
publishes the engine to PyPI through trusted publishing, signs and notarises the app with the
identity `scripts/ci-signing-secrets.sh` stored, and commits the updated cask to `main`.
`just release-macos --publish` does the app half from a Mac with the Developer ID certificate.
The PyPI trusted publisher is registered for this workflow and the `release` environment;
published distributions include publisher attestations. Version 0.4.1 was released locally.
See [release setup and the local fallback](#does-publication-happen-in-ci).
