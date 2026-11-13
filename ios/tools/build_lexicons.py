#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyarrow==26.0.1"]
# ///
"""Fetch AOSP LatinIME's English and Spanish word lists at a pinned commit, and Tatoeba's English and Spanish
sentences at a pinned revision, and compile them into the keyboard's compact lexicon format (.v2tlex). The
word lists are Apache-2.0 (LatinIME NOTICE), the sentences CC BY 2.0 FR; see ios/THIRD_PARTY_NOTICES.md.
Outputs are not committed: ios/setup.sh runs this before building.

    uv run tools/build_lexicons.py <out-dir>

Format (little-endian), sorted by folded key bytes, then frequency descending:
    "V2TL" u32 version=2, u32 count, u32 key_blob_len, u32 word_blob_len
    u32 key_offsets[count+1], u32 word_offsets[count+1], u8 freqs[count], key_blob, word_blob
    "BIGR" u32 pairs, u32 prev[pairs], u32 next[pairs], u8 cost[pairs], u8 lift[pairs]
The folded key is what a typist can produce on the letter keys: lowercase, accents and ñ folded to their
base letter, apostrophes and hyphens dropped ("don't" -> "dont", "año" -> "ano").

The bigram section lists, for each word (an entry index; 0xFFFFFFFF for the start of a sentence), the words
that most often follow it in the sentences, sorted by `prev` then by `cost`. `cost` is -ln P(next | prev) and
`lift` is ln(P(next | prev) / P(next)), floored at 0; both in sixteenths of a nat. Version 1 files have no
bigram section.
"""
import collections
import gzip
import hashlib
import io
import math
import re
import struct
import sys
import unicodedata
import urllib.request
from pathlib import Path

BUILD = 4  # bump when the output changes for the same inputs, so setup.sh rebuilds
COMMIT = "127336e9f29d69607eab55982324b210279ae8c5"  # LatinIME main, 2025-02-26
URL = "https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/{commit}/dictionaries/{name}?format=TEXT"
LISTS = {
    "en": ("en_US_wordlist.combined.gz", "0f78dd455b532be169a23f233227b811fabced4b5bd7fc9c40cc05839793bcbd"),
    "es": ("es_wordlist.combined.gz", "889ad52bce2933e2a30a0560b8d5a76f5334500e776a7db7c7cb3e9e79fc2652"),
}
# Tatoeba's English-Spanish sentence pairs as re-wrapped by sentence-transformers (2024-06-18 revision).
TATOEBA_REV = "cec1343ab5a7a8befe99af4a2d0ca847b6c84743"
TATOEBA_URL = ("https://huggingface.co/datasets/sentence-transformers/parallel-sentences-tatoeba/resolve/"
               f"{TATOEBA_REV}/en-es/train-00000-of-00001.parquet")
TATOEBA_SHA = "b62747cc931b16ec95f265b37e3328c0ea9f211c2e0eb3ceb309d5932af37448"
TATOEBA_COLUMN = {"en": "english", "es": "non_english"}

# AOSP flags words that are real but rarely meant when typing a message. They stay valid words (never
# autocorrected away) but lose this many frequency steps (about 0.08 nats each), so "govt" and "GRU" stop
# outranking "going" and "hey". Nonwords and offensive words drop to 0: valid, never suggested.
DEMOTED = {"abbreviation", "medical", "technical", "drugs", "babytalk", "australian"}
DEMOTION = 40
SILENCED = {"nonword", "offensive"}
# Bigrams: a word needs this many occurrences to get followers, a pair this many to be kept, and each word
# keeps its commonest followers. The start of a sentence keeps many more: it is where every message begins,
# and where chat words the word lists under-rate ("hey", "thanks") get their lift. On QualityEval, 24 and 300
# beat 12 and 12 on every sentence row (Spanish sentences 84.6% to 89.7% top-1) at 0.1 MB per language.
MIN_PREV, MIN_PAIR, FOLLOWERS, START_FOLLOWERS = 3, 2, 24, 300
START = 0xFFFFFFFF
# Chat abbreviations the English list lacks (chat_words_en.txt, each with its source), at the frequency the list
# gives its one chat abbreviation, "BTW" (100, less DEMOTION as an abbreviation). At 60 the swipe for "idk" in
# the owner's log decodes to it; RealTypoEval and QualityEval do not move, and NoisyTypingEval fixes as many
# mistapped words with one more wrong word of 19,952 on its test split (ios/AUTOCORRECT.md, "After a fourth
# typing log").
CHAT_WORDS = {"en": Path(__file__).with_name("chat_words_en.txt")}
CHAT_FREQUENCY = 60
TOKEN = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*")


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
        flags = set(fields.get("flags", "").split(":")) - {""}
        if "possibly_offensive" in line or flags & SILENCED:
            freq = 0
        elif flags & DEMOTED:
            freq = max(1, freq - DEMOTION) if freq > 0 else 0
        if word not in out or out[word][0] < freq:
            out[word] = (freq, key)
    return out


def add_chat_words(entries: dict[str, tuple[int, str]], path: Path) -> None:
    """Adds each word of `path` (word, tab, source; "#" comments) at CHAT_FREQUENCY, or keeps a higher one."""
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        word = line.split("\t")[0]
        old = entries.get(word, (0, fold(word)))[0]
        entries[word] = (max(old, CHAT_FREQUENCY), fold(word))


def sort_rows(entries: dict[str, tuple[int, str]]) -> list[tuple[bytes, int, str]]:
    return sorted((key.encode(), -freq, word) for word, (freq, key) in entries.items())


def bigrams(rows: list[tuple[bytes, int, str]], sentences: list[str]) -> list[tuple[int, int, int, int]]:
    """(prev, next, cost, lift) rows for the bigram section."""
    # each lowercase spelling maps to its commonest entry ("i" -> "I"); followers must be lowercase words
    # or "I" and its contractions, so the corpus's names (Tom, Mary) are never predicted
    entry: dict[str, tuple[int, int]] = {}
    for i, (_, negfreq, word) in enumerate(rows):
        low = word.lower()
        if low not in entry or -negfreq > entry[low][1]:
            entry[low] = (i, -negfreq)
    words = [w for _, _, w in rows]

    def followable(i: int) -> bool:
        w = words[i]
        return -rows[i][1] > 0 and (w == w.lower() or w == "I" or w.startswith("I'"))

    unigram, prev_count, pair = collections.Counter(), collections.Counter(), collections.Counter()
    for s in sentences:
        toks = [t.lower().replace("’", "'") for t in TOKEN.findall(s)]
        unigram.update(toks)
        seq = ["^"] + toks
        prev_count.update(seq[:-1])
        pair.update(zip(seq, seq[1:]))
    total = sum(unigram.values())
    by_prev: dict[int, list[tuple[int, int, int]]] = collections.defaultdict(list)
    for (a, b), c in pair.items():
        if c < MIN_PAIR or prev_count[a] < MIN_PREV or b not in entry:
            continue
        p = START if a == "^" else entry.get(a, (None,))[0]
        n = entry[b][0]
        if p is None or not followable(n):
            continue
        cost = -math.log(c / prev_count[a])
        lift = math.log(c * total / (prev_count[a] * unigram[b]))
        by_prev[p].append((n, min(255, round(cost * 16)), max(0, min(255, round(lift * 16)))))
    out = []
    for p in sorted(by_prev):
        kept = sorted(by_prev[p], key=lambda r: (r[1], r[0]))[:START_FOLLOWERS if p == START else FOLLOWERS]
        out += [(p, n, cost, lift) for n, cost, lift in kept]
    return out


def compile_lexicon(rows: list[tuple[bytes, int, str]], pairs: list[tuple[int, int, int, int]]) -> bytes:
    keys, words, freqs = bytearray(), bytearray(), bytearray()
    key_offsets, word_offsets = [0], [0]
    for key, negfreq, word in rows:
        keys += key
        words += word.encode()
        key_offsets.append(len(keys))
        word_offsets.append(len(words))
        freqs.append(-negfreq)
    n = len(rows)
    header = b"V2TL" + struct.pack("<IIII", 2, n, len(keys), len(words))
    m = len(pairs)
    section = (b"BIGR" + struct.pack("<I", m) + struct.pack(f"<{m}I", *(r[0] for r in pairs))
               + struct.pack(f"<{m}I", *(r[1] for r in pairs)) + bytes(r[2] for r in pairs) + bytes(r[3] for r in pairs))
    return (header + struct.pack(f"<{n + 1}I", *key_offsets) + struct.pack(f"<{n + 1}I", *word_offsets)
            + bytes(freqs) + bytes(keys) + bytes(words) + section)


def download(url: str, sha: str, name: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    got = hashlib.sha256(data).hexdigest()
    if got != sha:
        raise SystemExit(f"{name}: sha256 {got} != pinned {sha}")
    return data


def fetch(name: str, sha: str) -> bytes:
    import base64

    with urllib.request.urlopen(URL.format(commit=COMMIT, name=name), timeout=60) as r:
        data = base64.b64decode(r.read())
    got = hashlib.sha256(data).hexdigest()
    if got != sha:
        raise SystemExit(f"{name}: sha256 {got} != pinned {sha}")
    return data


def tatoeba() -> dict[str, list[str]]:
    import pyarrow.parquet as pq

    table = pq.read_table(io.BytesIO(download(TATOEBA_URL, TATOEBA_SHA, "tatoeba en-es")))
    # a sentence translated several times appears once per pair; count it once
    return {lang: sorted(set(table.column(col).to_pylist())) for lang, col in TATOEBA_COLUMN.items()}


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    sentences = None
    for lang, (name, sha) in LISTS.items():
        target = out / f"{lang}.v2tlex"
        stamp = out / f"{lang}.v2tlex.src"
        chat = CHAT_WORDS.get(lang)
        chat_sha = hashlib.sha256(chat.read_bytes()).hexdigest() if chat else "-"
        source = f"{BUILD} {COMMIT} {sha} {TATOEBA_REV} {TATOEBA_SHA} {chat_sha}\n"
        if target.exists() and stamp.exists() and stamp.read_text() == source:
            continue
        sentences = sentences or tatoeba()
        entries = parse(gzip.decompress(fetch(name, sha)).decode())
        if chat:
            add_chat_words(entries, chat)
        rows = sort_rows(entries)
        pairs = bigrams(rows, sentences[lang])
        target.write_bytes(compile_lexicon(rows, pairs))
        stamp.write_text(source)
        print(f"{target}: {len(entries)} words, {len(pairs)} bigrams, {target.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
