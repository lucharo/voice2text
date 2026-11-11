# Documentation index

Luis confirmed on 5 November 2026 that current user and maintainer documentation may be rewritten. Historical reports, dated experiments and raw benchmark records retain their original meaning. The site builds only `docs/public/`; this index and the dictionary remain contributor metadata.

<!-- doc-index:begin -->
| Doc | What | Class | Owns |
| --- | --- | --- | --- |
| `README.md` | Decide whether to install | evergreen | `pyproject.toml`, `Casks/*` |
| `docs/public/index.md` | First useful result | evergreen | `v2t/cli.py` |
| `docs/public/getting-started.md` | Install, grant permissions and dictate | evergreen | `v2t/app.py`, `v2t/menubar.py`, `Casks/*` |
| `docs/public/guide.md` | Files, cleanup, history and dictionary | evergreen | `v2t/cli.py`, `v2t/config.py`, `v2t/backends.py` |
| `docs/public/iphone.md` | iPhone setup, dictation and device limits | evergreen | `ios/App/*`, `ios/Keyboard/*`, `ios/Shared/*` |
| `docs/public/privacy.md` | Data use and local storage | evergreen | `ios/App/*`, `v2t/app.py` |
| `docs/public/how-it-works.md` | Default Mac dictation path | evergreen | `v2t/app.py`, `v2t/backends.py`, `v2t/coreml.py` |
| `docs/public/faq.md` | Resolve common visible problems | evergreen | `v2t/app.py`, `v2t/config.py`, `v2t/native/Voice2Text.swift` |
| `docs/public/reference/cli.md` | Supported commands and flags | evergreen | `v2t/cli.py` |
| `docs/public/reference/config.md` | Configuration keys and defaults | evergreen | `v2t/config.py`, `v2t/backends.py` |
| `docs/public/benchmarks.md` | Interpret published historical measurements | evergreen | `docs/public/assets/benchmarks.json`, `docs/public/javascripts/benchmarks.js`, `utils/model_intake/*` |
| `docs/public/maintainers/index.md` | Build, check and release | evergreen | `justfile`, `.github/workflows/*` |
| `ios/README.md` | Current iOS contributor instructions | evergreen | `ios/App/*`, `ios/Shared/*`, `ios/project.yml` |
| `docs/DICTIONARY.md` | Load-bearing terminology | evergreen | — |
| `internal/**`, dated reports, experiment logs and raw result records | Preserve historical decisions and measurements | point-in-time | — |
<!-- doc-index:end -->
