---
name: v2t-dictionary
description: >
  Grow `~/.v2t/dictionary.txt` from what a transcript got wrong, with `v2t dictionary`.
  Turns the names, products and acronyms a dictation misheard into `heard => written`
  replacements and vocabulary terms, then proves each new line fires. Use when a user
  corrects a v2t transcript ("that's alphaXiv, not Alpha Kive"), when tidying a transcript
  surfaces mishearings, or on "add this to my dictionary" / "teach v2t this word".
  Transcribing audio in the first place is `v2t-transcribe`.
allowed-tools:
  - Bash
  - Read
---

# Teach v2t a transcript's mishearings

`~/.v2t/dictionary.txt` holds two kinds of line, and they act at different points:

| Line | What it does | When it applies |
|---|---|---|
| `heard => written` | whole-word, case-insensitive substitution, in file order | every transcription, cleanup on or off |
| `Term` | tells the cleanup model to spell it exactly like this when it hears something similar | LLM cleanup only (`v2t` dictation, `v2t transcribe --clean`) |

A replacement is therefore the only line that fixes verbatim `v2t transcribe` output. A term is
a hint, and every term rides along in every cleanup call, so the list stays lean.

## Steps

1. **Put raw and corrected side by side.** Raw is what v2t produced; corrected is the user's
   reading of it: their edits, their "that's X not Y", or the tidy pass just done with them.
   `v2t history <term> --json` re-emits a dictation's raw and clean text when only a fragment is
   at hand; `v2t transcribe` output is already raw. Done when every correction is a
   `(heard, written)` pair on one list.
2. **Keep only the spelling of things.** Names, products, papers, acronyms, repo names, jargon.
   Grammar, dropped words and filler belong to the transcript, not the dictionary. Done when
   each pair names something the recogniser will meet again.
3. **Classify each pair** with the table below, then read `v2t dictionary show` for an entry
   that already covers it, or one that would rewrite its input first (entries run in file
   order). Done when each pair is marked replacement, term, or skipped with a reason.
4. **Add them, one entry per call.** The arguments of a single call are joined into one entry:

   ```bash
   v2t dictionary add "Navio Stokes => Navier-Stokes"
   v2t dictionary add "Navier-Stokes"
   ```

   The file is rewritten deduped (case-insensitive), with the user's own comments kept.
5. **Prove the replacements fire** on the raw text:

   ```bash
   v2t dictionary apply raw.txt          # or:  pbpaste | v2t dictionary apply
   ```

   stdout is the raw text with the replacements applied; stderr names the entries that fired.
   Done when every replacement added in step 4 is in that list. A term cannot be checked this
   way; it shows only in the next cleanup pass. When the audio is still around
   (`~/.v2t/run/last-recording.wav` is the most recent dictation), `v2t transcribe --clean` it with the
   mode the dictation used (`--casual` is the default) and grep; terms only show through cleanup.
6. **Report** the entries added, the pairs skipped and why, and any spelling you had to ask
   about.

## Replacement or term

| Heard form | Add | Because |
|---|---|---|
| Something nobody dictates on purpose: `Navio Stokes`, `ICL our`, `OrgorL` | replacement, plus the term | safe to rewrite everywhere |
| A real word or phrase with its own meaning: `NPR` for "in PR", `Lee`, `purchase` | term only | the replacement would fire on genuine uses |
| Misheard differently each time | term only | no stable string to match |
| Right spelling unknown (`Kime Te`?) | ask the user first | a wrong `written` side corrupts every future dictation |
| A single common word | prefer a two-word form or a non-word | fewer false matches |

The `heard` side matches at word boundaries and ignores case, so `whisper flow` covers
`Whisper Flow`; the `written` side is inserted literally.
