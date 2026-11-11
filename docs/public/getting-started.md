# Getting started

## What you need

- An Apple Silicon Mac.
- [uv](https://docs.astral.sh/uv/) and Python 3.11 to 3.13. uv downloads Python if needed.
- A few gigabytes of free disk space for the models.

## Install and dictate

```bash
uv tool install --python 3.13 voice2text
v2t
```

Keep `--python 3.13`: the default Core ML backend has no native library for Python 3.14. The first launch downloads the models. Leave the terminal running.

1. Grant your terminal **Microphone** and **Accessibility** access in System Settings → Privacy & Security. Restart `v2t` after granting access if prompted.
2. In System Settings → Keyboard, set **Press 🌐 key to** to **Do Nothing**.
3. Wait until `v2t status` in another terminal starts with `idle`.
4. Click a text field, hold **Fn**, speak, then let go. The text should appear there.

| Action | Keys |
|---|---|
| Dictate hands-free | Double-tap Fn; tap once to finish |
| Cancel | Esc |
| Undo a cancel in the menu app | Cmd+Z within 5 seconds |
| Stop the terminal engine | Ctrl+C |

If nothing happens, start with [Help](faq.md).

## The menu app (optional)

The menu app adds its own permissions, a status icon and a dictation bubble. Install the engine above first, then:

```bash
brew trust --tap lucharo/voice2text
brew trust --cask lucharo/voice2text/voice2text
brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git
brew install --cask voice2text
```

Stop the terminal engine with Ctrl+C, then open **Voice2Text** in `/Applications` and grant its Microphone and Accessibility permissions. The menu says **Ready** once the models load.

To start the menu app at login, quit **Voice2Text**, then run:

```bash
v2t service install
```

## Update

```bash
uv tool upgrade voice2text
```

If you installed the menu app, also run `brew upgrade --cask voice2text`. Choose **Restart v2t** in its menu, or stop and rerun the terminal engine.

For another hotkey or model, see [configuration](reference/config.md). Keep the defaults for a first dictation.

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-05 · commit `4d5dcb4` · verified against code._
