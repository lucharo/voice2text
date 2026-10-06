# Getting started

## What you need

- A Mac with Apple Silicon. v2t runs on [MLX](https://github.com/ml-explore/mlx), so Intel Macs,
  Linux and Windows are out of scope.
- [uv](https://docs.astral.sh/uv/) and Python 3.11 or later.
- A few gigabytes of disk for the two models, downloaded once from Hugging Face on first launch.

## Install the engine

```bash
uv tool install voice2text
v2t
```

The first launch downloads Parakeet and the cleanup model, then loads them from the local cache
in about 2 s on every later start. Leave `v2t` running in the terminal. It is ready when the log
prints `Hold fn to record, release to transcribe and paste`, and `v2t status` in another terminal
starts with `idle`.

Prefer Whisper for transcription? Add the extra, quoted so zsh leaves the brackets alone:

```bash
uv tool install 'voice2text[whisper]'
```

Then set `backend = "whisper"` in the [config](reference/config.md).

## Free the Fn key

v2t listens for **Fn** (the 🌐 key, bottom left). macOS uses it for the emoji picker unless you
change one setting:

- System Settings → Keyboard → *Press 🌐 key to* → **Do Nothing**.

v2t warns in its log while that setting is anything else. Prefer Right Command? Set
`key = "cmd_r"` under `[hotkey]`.

## Dictate

| To | Do |
|---|---|
| Dictate | Hold Fn, talk, let go |
| Dictate hands-free | Double-tap Fn, talk, tap Fn once to finish |
| Cancel | Press Esc while recording |
| Undo a cancel | Cmd+Z within 5 s (menu app) |

Nothing shows until the key has been down for half a second, so a quick tap or an Fn shortcut
(Fn+arrow) leaves no trace.

## Permissions

v2t needs two macOS permissions:

- **Microphone**, to record.
- **Accessibility**, for the global hotkey and the paste.

Run from a terminal, v2t uses that terminal's grants, so add your terminal app to both lists in
System Settings → Privacy & Security.

## The menu app (optional)

The menu app gives v2t its own permissions, a menu-bar icon that shows its state, and a small pill
that floats over every app while you dictate. It is signed and notarised, so it installs on managed
work Macs too:

```bash
brew trust --tap lucharo/voice2text && brew trust --cask lucharo/voice2text/voice2text
brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git
brew install --cask voice2text
```

The first line is needed because Homebrew 6 loads no third-party tap it has not been told to trust.
Open **Voice2Text** from `/Applications` and grant the two permissions it asks for. Once both are
granted, opening the app starts v2t, so later launches need no click. The menu shows **Ready** once
the models are loaded.

To start it at login:

```bash
v2t service install
```

The menu app runs the engine you installed with uv; it does not replace it.

## Update

```bash
uv tool upgrade voice2text
brew upgrade --cask voice2text
```

Then choose **Stop v2t** and **Start v2t** in the menu, or restart `v2t` in the terminal.

??? note "Other ways to install"

    ```bash
    uvx --from voice2text v2t        # try it without installing (slower start)
    pip install voice2text && v2t    # plain pip
    git clone https://github.com/lucharo/voice2text.git && cd voice2text
    uv sync --no-dev && uv run v2t   # from source
    ```
