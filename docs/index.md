# voice2text

**Voice-as-an-Interface, done simply.**

[![PyPI](https://img.shields.io/pypi/v/voice2text)](https://pypi.org/project/voice2text/)
[![macOS on Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon-blue?logo=apple)](getting-started.md#what-you-need)
[![Licence: GPL-2.0](https://img.shields.io/badge/licence-GPL--2.0-green)](https://github.com/lucharo/voice2text/blob/main/LICENSE)

- Hold a key, talk, let go: the text is pasted where your cursor is.
- Everything runs on your Mac. [Parakeet](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
  transcribes, a small local LLM tidies the punctuation, and nothing leaves the machine.
- No account, no daemon, no network once the models are cached, so a corporate VPN or proxy
  never gets in the way.

Speech-to-text as boring technology: just another peripheral.

```bash
uv tool install voice2text
v2t
```

Hold **Fn**, say something, let go. The text lands in whatever app has focus.

## Where next

<div class="grid cards" markdown>

- **[Getting started](getting-started.md)**: install, permissions, the menu app, a first dictation.
- **[How it works](how-it-works.md)**: what happens while you hold the key, and why.
- **[Guide](guide.md)**: files, cleanup modes, history and the dictionary.
- **[Reference](reference/cli.md)**: every command and every config key.

</div>
