#!/usr/bin/env python3
"""Fetch AOSP LatinIME's English and Spanish word lists at a pinned commit and compile them into the
keyboard's compact lexicon format (.v2tlex). The lists are Apache-2.0 (LatinIME NOTICE); see
ios/THIRD_PARTY_NOTICES.md. Outputs are not committed: ios/setup.sh runs this before building.

    ./build_lexicons.py <out-dir>

Format (little-endian), sorted by folded key bytes, then frequency descending:
    "V2TL" u32 version=1, u32 count, u32 key_blob_len, u32 word_blob_len
    u32 key_offsets[count+1], u32 word_offsets[count+1], u8 freqs[count], key_blob, word_blob
The folded key is what a typist can produce on the letter keys: lowercase, accents and ñ folded to their
base letter, apostrophes and hyphens dropped ("don't" -> "dont", "año" -> "ano").
"""
import gzip
import hashlib
import struct
import sys
import unicodedata
import urllib.request
from pathlib import Path

COMMIT = "127336e9f29d69607eab55982324b210279ae8c5"  # LatinIME main, 2025-02-26
URL = "https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/{commit}/dictionaries/{name}?format=TEXT"
LISTS = {
    "en": ("en_US_wordlist.combined.gz", "0f78dd455b532be169a23f233227b811fabced4b5bd7fc9c40cc05839793bcbd"),
    "es": ("es_wordlist.combined.gz", "889ad52bce2933e2a30a0560b8d5a76f5334500e776a7db7c7cb3e9e79fc2652"),
}


def fold(word: str) -> str:
    decomposed = unicodedata.normalize("NFD", word.lower())
    return "".join(c for c in decomposed if "a" <= c <= "z")


def parse(text: str) -> dict[str, tuple[int, str]]:
    """word -> (freq, key). Offensive or zero-frequency words stay as valid words with freq 0, so they are
    never autocorrected away but never suggested either."""
    out: dict[str, tuple[int, str]] = {}
    for line in text.splitlines():
        if not line.startswith(" word="):
            continue
        fields = dict(f.split("=", 1) for f in line.strip().split(",") if "=" in f)
        word = fields["word"]
        if fields.get("not_a_word") == "true" or any(ch.isdigit() for ch in word):
            continue
        key = fold(word)
        if not key:
            continue
        freq = int(fields.get("f", "0"))
        if "possibly_offensive" in line:
            freq = 0
        if word not in out or out[word][0] < freq:
            out[word] = (freq, key)
    return out


def compile_lexicon(entries: dict[str, tuple[int, str]]) -> bytes:
    rows = sorted(((key.encode(), -freq, word) for word, (freq, key) in entries.items()))
    keys, words, freqs = bytearray(), bytearray(), bytearray()
    key_offsets, word_offsets = [0], [0]
    for key, negfreq, word in rows:
        keys += key
        words += word.encode()
        key_offsets.append(len(keys))
        word_offsets.append(len(words))
        freqs.append(-negfreq)
    n = len(rows)
    header = b"V2TL" + struct.pack("<IIII", 1, n, len(keys), len(words))
    return (header + struct.pack(f"<{n + 1}I", *key_offsets) + struct.pack(f"<{n + 1}I", *word_offsets)
            + bytes(freqs) + bytes(keys) + bytes(words))


def fetch(name: str, sha: str) -> bytes:
    import base64

    with urllib.request.urlopen(URL.format(commit=COMMIT, name=name), timeout=60) as r:
        data = base64.b64decode(r.read())
    got = hashlib.sha256(data).hexdigest()
    if got != sha:
        raise SystemExit(f"{name}: sha256 {got} != pinned {sha}")
    return data


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for lang, (name, sha) in LISTS.items():
        target = out / f"{lang}.v2tlex"
        stamp = out / f"{lang}.v2tlex.src"
        if target.exists() and stamp.exists() and stamp.read_text() == f"{COMMIT} {sha}\n":
            continue
        entries = parse(gzip.decompress(fetch(name, sha)).decode())
        target.write_bytes(compile_lexicon(entries))
        stamp.write_text(f"{COMMIT} {sha}\n")
        print(f"{target}: {len(entries)} words, {target.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
