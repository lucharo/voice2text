#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fetch the phone taps of Vertanen and Kristensson's noisy-typing dataset at a pinned version, and write them as
plain files for `swift test --filter NoisyTypingEval`. Not committed; ios/setup.sh runs this.

    uv run tools/fetch_noisy_typing.py <out-dir>

Source (see ios/THIRD_PARTY_NOTICES.md): Keith Vertanen and Per Ola Kristensson, "A Dataset of Noisy Typing on
QWERTY Keyboards" (IUI 2023), https://osf.io/5xwng/, file vertanen_noisy_typing_iui2023.zip version 1 (18 MB),
CC BY 4.0. Its phone group is sentences copied from the Enron mobile set on an iPhone 4 or a Nexus 4 keyboard,
typed a whole sentence before any recognition, often with no visual feedback, some blindfolded or on smaller
keyboards. Only the `dev_word` and `test_word` folders are kept: the authors force aligned each sentence's taps
to its reference words, so they can be typed a word at a time. `eyesfree_exp2` has no such folders and is left out.

Outputs:
- keyboards.txt: one letter key a line, `keyboard TAB letter TAB centre x TAB centre y TAB width TAB height`,
  in the dataset's own coordinates. The keyboard id is `<study>/<layout file stem>`. Space and backspace keys
  are left out: the word-aligned taps hold letters only.
- dev.txt and test.txt: one sentence a line,
  `source TAB keyboard TAB phrase id TAB reference words TAB taps`, where source is `<study>/<log file stem>`,
  the reference is lowercase letters and single spaces, and taps holds one group per reference word, separated
  by spaces; a group's taps are separated by `;`, each `down x,down y,up x,up y` (where the finger landed and
  where it lifted; the dataset logs every point between, with times, which are dropped). Sentences whose number
  of word groups differs from their number of words are dropped.
"""
import hashlib
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

BUILD = 1  # bump when the output changes for the same inputs
UA = {"User-Agent": "voice2text-keyboard-eval/1.0 (https://github.com/lucharo/voice2text)"}
URL = "https://osf.io/download/7ev5z/?version=1"
SHA = "76d9cc798b5694686333da8baec46ce025174068bbfef909a31fe01e67dcdf5d"
SPLITS = {"dev": "dev_word", "test": "test_word"}
LAYOUT_SUFFIX = re.compile(r"_(normal|small|tiny)$")


def fetch(url: str, sha: str) -> bytes:
    data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=300).read()
    got = hashlib.sha256(data).hexdigest()
    if got != sha:
        sys.exit(f"{url}: sha256 {got}, expected {sha}")
    return data


def keyboard_file(names: list[str], study: str, stem: str) -> str:
    """The layout file of a study's log: vt_exp3 has one a keyboard size, named by the log's suffix."""
    files = sorted(n for n in names if re.fullmatch(rf"noisy_typing/phone/{study}/keyboard_[^/]+\.txt", n))
    m = LAYOUT_SUFFIX.search(stem)
    if len(files) > 1 and m:
        files = [f for f in files if f.endswith(f"_{m.group(1)}.txt")]
    if len(files) != 1:
        sys.exit(f"{study}/{stem}: layout files {files}")
    return files[0]


def keys(text: str) -> list[tuple[str, str, str, str, str]]:
    out = []
    for line in text.splitlines():
        parts = [p.strip() for p in line.split(";")]
        if line.startswith("#") or len(parts) != 5 or not re.fullmatch(r"[a-z]", parts[0]):
            continue
        out.append(tuple(parts))
    if len(out) != 26:
        sys.exit(f"layout with {len(out)} letters")
    return out


def num(s: str) -> str:
    return f"{float(s):g}"


def tap(event: str) -> str:
    points = [p.split(",") for p in event.split(":")[0].split(";") if p]
    down, up = points[0], points[-1]
    return f"{num(down[0])},{num(down[1])},{num(up[0])},{num(up[1])}"


def sentences(text: str) -> tuple[list[tuple[str, str, list[str]]], int]:
    """(phrase id, reference words, a tap group a word) for each aligned sentence, and how many were dropped."""
    out, dropped = [], 0
    for block in text.split("\n\n"):
        fields: dict[str, list[str]] = {}
        for line in block.splitlines():
            if ": " in line:
                k, v = line.split(": ", 1)
                fields.setdefault(k, []).append(v.strip())
        if "REF" not in fields:
            continue
        words = fields["REF"][0].split()
        groups = fields.get("IN", [])
        if len(groups) != len(words) or not all(re.fullmatch(r"[a-z]+", w) for w in words):
            dropped += 1
            continue
        out.append((fields["ID"][0], words, [";".join(tap(e) for e in g.split("|")) for g in groups]))
    return out, dropped


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/noisy-typing")
    stamp = out / "stamp"
    want = f"{BUILD} {URL} {SHA}"
    if stamp.exists() and stamp.read_text() == want:
        return
    out.mkdir(parents=True, exist_ok=True)
    z = zipfile.ZipFile(io.BytesIO(fetch(URL, SHA)))
    names = z.namelist()
    layouts: dict[str, list[tuple[str, ...]]] = {}
    for split, folder in SPLITS.items():
        lines, words, dropped = [], 0, 0
        logs = sorted(n for n in names if re.fullmatch(rf"noisy_typing/phone/[^/]+/{folder}/[^/]+\.log", n))
        for name in logs:
            study, stem = name.split("/")[2], Path(name).stem
            kb_name = keyboard_file(names, study, stem)
            kb = f"{study}/{Path(kb_name).stem}"
            layouts.setdefault(kb, keys(z.read(kb_name).decode("utf-8")))
            rows, d = sentences(z.read(name).decode("utf-8"))
            dropped += d
            for pid, ws, groups in rows:
                lines.append(f"{study}/{stem}\t{kb}\t{pid}\t{' '.join(ws)}\t{' '.join(groups)}\n")
                words += len(ws)
        (out / f"{split}.txt").write_text("".join(lines))
        print(f"{out}/{split}.txt: {len(lines)} sentences, {words} words, from {len(logs)} logs; {dropped} dropped")
    (out / "keyboards.txt").write_text("".join(f"{kb}\t" + "\t".join(k) + "\n" for kb, ks in sorted(layouts.items()) for k in ks))
    print(f"{out}/keyboards.txt: {len(layouts)} layouts")
    stamp.write_text(want)


if __name__ == "__main__":
    main()
