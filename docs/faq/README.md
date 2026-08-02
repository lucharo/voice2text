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
