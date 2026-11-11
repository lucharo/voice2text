# Maintainers

Use an Apple Silicon Mac with uv and the Xcode command-line tools.

| Task | Command |
|---|---|
| Set up | `uv sync --frozen` |
| Lint | `just lint` |
| Check Python and type-check Swift | `just check` |
| Check and build the wheel and sdist | `just build` |
| Build the docs | `uv run --frozen --only-group docs zensical build --clean --strict` |
| Benchmark this Mac | `just bench` |

## Release

### Do releases run through CI?

Yes. Mac version tags publish the Mac release. Eligible iOS changes on `main` upload to TestFlight. An `ios-v*` tag submits a selected build for App Store review.

1. Update the version in `pyproject.toml`, `v2t/__init__.py` and the `voice2text` entry in `uv.lock`; update `CHANGELOG.md`.
2. Run the checks and review the release commit.
3. Push a matching `v<version>` tag from the merged commit. The [release workflow](https://github.com/lucharo/voice2text/blob/main/.github/workflows/release.yml) publishes to PyPI, signs and notarises the Mac app, and updates the cask.
4. Verify the published distributions, downloaded app and cask. A green build alone does not verify publication.

### iPhone app

Eligible iOS changes on `main` run the [TestFlight workflow](https://github.com/lucharo/voice2text/blob/main/.github/workflows/testflight.yml): correctness tests, archive, upload and processing check. Its path filters exclude iOS Markdown and designated test directories; manual dispatch also uploads `main`. The keyboard logging microbenchmark runs separately as an informational shared-runner measurement. It is not a phone model benchmark.

#### How do I promote a TestFlight build to the App Store?

To promote a tested build, push an annotated `ios-v<version>-<build>` tag with the release notes as its message, for example `ios-v1.0.1-123`. Omitting the build selects the newest processed build of that version. The [App Store workflow](https://github.com/lucharo/voice2text/blob/main/.github/workflows/appstore.yml) submits it for Apple's review and enables release after approval. Manual dispatch is a read-only dry run.

After a version reaches the App Store, raise `MARKETING_VERSION` in `ios/project.yml` before uploading another build. App Store review and external TestFlight beta review have independent states.

#### How do I invite friends or get a shareable TestFlight link?

Add a processed build and the testers to an external group in App Store Connect. Submit the build for Beta App Review and enable automatic notification. Once the build is available, Apple sends the email invitations. To share a link instead, enable **Public Link** on that group and copy it. Keep the link disabled when inviting only named testers.

These operations can be automated through the [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi). External testing needs an Account Holder, Admin or App Manager role. Read back group membership, beta-review status and invitation status separately; adding a tester does not establish that they installed the build. See [Apple's external testing instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/).

<!-- FAQ dates: Created 2026-11-11; Updated 2026-11-11; Verified 2026-11-11. Sources: linked workflows, ios/tools/asc.py and Apple instructions. -->

## Benchmarks and docs

[Mac benchmark commands](https://github.com/lucharo/voice2text/blob/main/benchmarks/README.md), the [speech-model grid](https://github.com/lucharo/voice2text/tree/main/utils/asr_grid) and the [phone harness](https://github.com/lucharo/voice2text/tree/main/utils/phone_bench) own their run instructions. The public [benchmark page](../benchmarks.md) explains the recorded results.

Current user docs live in `docs/public/`; the documentation index and dictionary are in `docs/`. Historical records live in `internal/` and are not built into the site. Docs changes must pass the strict build and a reader check; `main` deploys through the [docs workflow](https://github.com/lucharo/voice2text/blob/main/.github/workflows/docs.yml).

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-05 · commit `4d5dcb4` · verified against code._
