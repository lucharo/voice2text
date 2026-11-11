# `voice2text`

[![check](https://img.shields.io/github/actions/workflow/status/lucharo/voice2text/check.yml?branch=main&label=check)](https://github.com/lucharo/voice2text/actions/workflows/check.yml)
[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue?logo=apple)](https://v2t.luischav.es/getting-started/)
[![Licence: GPL-2.0](https://img.shields.io/badge/licence-GPL--2.0-green)](LICENSE)

**Voice-as-an-Interface, done simply.** Hold a key, talk, let go. Your words are pasted into your current app.

The default speech and cleanup models run on your Apple Silicon Mac. Model files download on first use.

```bash
uv tool install --python 3.13 voice2text
v2t
```

Grant Microphone and Accessibility permissions, then hold **Fn** to dictate. The optional menu app adds a status icon and dictation bubble.

[Get started](https://v2t.luischav.es/getting-started/) · [Guide](https://v2t.luischav.es/guide/) · [Benchmarks](https://v2t.luischav.es/benchmarks/) · [Reference](https://v2t.luischav.es/reference/cli/) · [Help](https://v2t.luischav.es/faq/)

The iPhone app is free on the [App Store](https://apps.apple.com/app/id6831059370). See the [iPhone and iPad guide](https://v2t.luischav.es/iphone/).

Contributors: `uv sync`, then `just check`. See the [maintainer docs](https://v2t.luischav.es/maintainers/).

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-05 · commit `4d5dcb4` · verified against code._
