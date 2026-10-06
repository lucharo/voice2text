# Internal notes

Maintainer-only records. They stay in Git but are never built into the docs site (zensical only
reads `docs/`) or packed into the sdist (`pyproject.toml` lists what the sdist includes). Public
pages never link here.

| File | Holds |
|---|---|
| [releasing.md](releasing.md) | How each release went: CI publication, the PyPI outage, the local Mac fallback, signing |
| [streaming.md](streaming.md) | The measurements behind the 60 s rule and why the streamed text differs |
| [faq-evidence.md](faq-evidence.md) | The user FAQ's original entries, with code sources, measurements and verification dates |

Speech-model and cleanup evaluations keep their own READMEs under `utils/`; their per-clip results
stay private under `~/.v2t/eval` and never enter the repository.

## Open verification gaps

- Live interaction with the pill selector was not exercised in the 5 October audit.
- Installation and a real dictation on the work Mac after the 0.5.3 release are separate checks.
- The launchd-without-bundle path has not been re-tested on macOS 26.
