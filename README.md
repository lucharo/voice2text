# `voice2text`

[![check](https://img.shields.io/github/actions/workflow/status/lucharo/voice2text/check.yml?branch=main&label=check)](https://github.com/lucharo/voice2text/actions/workflows/check.yml)
[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![Downloads](https://static.pepy.tech/badge/voice2text/month)](https://pepy.tech/project/voice2text)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue?logo=apple)](https://v2t.luischav.es/getting-started/)
[![Licence: GPL-2.0](https://img.shields.io/badge/licence-GPL--2.0-green)](LICENSE)
[![Works on my machine](https://img.shields.io/badge/works-on%20my%20machine-brightgreen)](https://github.com/lucharo/voice2text)

**Voice-as-an-Interface, done simply.**

- Hold a key, talk, let go: the text is pasted where your cursor is.
- Everything runs on your Mac: [Parakeet](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
  transcribes and a small local LLM tidies the punctuation, both on [MLX](https://github.com/ml-explore/mlx).
- No account, no daemon, no network once the models are cached, so a corporate VPN or proxy never
  gets in the way.

Speech-to-text as boring technology: just another peripheral.

**Docs: [v2t.luischav.es](https://v2t.luischav.es/)**

```bash
uv tool install voice2text
v2t
```

Hold **Fn**, say something, let go. The optional menu-bar app adds its own permissions, a state
icon and a floating pill while you dictate:

```bash
brew trust --tap lucharo/voice2text && brew trust --cask lucharo/voice2text/voice2text
brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git
brew install --cask voice2text
```

## Docs

- [Getting started](https://v2t.luischav.es/getting-started/): install, permissions, the menu app
- [How it works](https://v2t.luischav.es/how-it-works/): what happens while you hold the key
- [Guide](https://v2t.luischav.es/guide/): files, cleanup modes, history, dictionary
- [Reference](https://v2t.luischav.es/reference/cli/): every command and config key
- [FAQ](https://v2t.luischav.es/faq/)

## Contributing

`uv sync`, then `just check`. See the [maintainer docs](https://v2t.luischav.es/maintainers/).

This started as a single `voice2text.py` under 300 lines, preserved at the
[`nano`](https://github.com/lucharo/voice2text/releases/tag/nano) tag.
