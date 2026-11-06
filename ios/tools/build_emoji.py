#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fetch Unicode's emoji-test.txt at a pinned Emoji version and write the keyboard's emoji panel data,
ios/Keyboard/emoji.txt; and fetch Unicode CLDR's English and Spanish emoji annotations at a pinned release
and write the search and suggestion keywords, one file per language, ios/Keyboard/emoji-keywords-<lang>.txt
(English "pie" is 🥧, Spanish "pie" a foot, so the languages stay apart). The outputs are committed
(they change only when a pinned version does); rerun after changing a version and its SHA256:

    uv run tools/build_emoji.py

The data is Unicode's (emoji-test.txt and CLDR), under the Unicode License v3; see ios/THIRD_PARTY_NOTICES.md.

Emoji 16.0 is the newest version every iOS this app supports draws (iOS 18.4 added it; the app needs iOS 26).

Format: UTF-8 text. Lines starting with "#" are comments. "@<category>" starts a category, in the order of
Apple's emoji keyboard; each following line holds one emoji, its skin-tone variants after it separated by
commas (light, medium-light, medium, medium-dark, dark). Only fully-qualified emoji are kept, in Unicode's
(CLDR) order. Unicode's "Smileys & Emotion" and "People & Body" groups share Apple's "Smileys & People"
category, Activities comes before Travel & Places as on Apple's keyboard, and the Component group (bare skin
tones and hair styles) is left out. A variant is kept when every skin tone in it is the same one; mixed-tone
pairs ("handshake: light skin tone, dark skin tone") are left out, as they need Apple's two-tone picker.

Keywords format: UTF-8 text, "#" comment lines, then one line per keyword: the keyword folded (lowercase,
accents and ñ taken off, as v2t's letter keys type it), a tab, and the emoji it names (base forms, as in
emoji.txt), separated by spaces. Lines are sorted by the keyword's UTF-8 bytes so the keyboard can
binary-search them. A keyword's emoji come first those whose name is the keyword ("pizza" -> 🍕), then those
whose name holds it as a word, then the rest in panel order. Keywords are CLDR's annotations and derived annotations
(flags, keycaps, sequences) and each emoji's name ("tts"), in English and Spanish; a name of several words also
counts as one keyword ("red heart"), and the part of a name after ": " too ("flag: Spain" gives "spain").
Each file holds one language's keywords.
"""
import hashlib
import json
import sys
import unicodedata
import urllib.request
from pathlib import Path

VERSION = "16.0"
URL = f"https://www.unicode.org/Public/emoji/{VERSION}/emoji-test.txt"
SHA256 = "24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697"
OUT = Path(__file__).resolve().parent.parent / "Keyboard" / "emoji.txt"
LANGS = ("en", "es")


def keywords_out(lang: str) -> Path:
    return OUT.with_name(f"emoji-keywords-{lang}.txt")
CLDR = "47.0.0"
CLDR_URL = ("https://raw.githubusercontent.com/unicode-org/cldr-json/{v}/cldr-json/cldr-annotations-full/annotations/"
            "{lang}/annotations.json")
CLDR_SHA256 = {
    "en": "2405d3f2e4c5812a4faf93d965630246269e0177ce907d863c7d6bb197e957c1",
    "es": "1e6fa1a8b9eb4a8b60132609ae2482cf4ad088b9d2590648933b595660f30648",
}
# The derived annotations name the emoji the ordinary ones leave out: flags ("flag: Spain"), keycaps and
# family or job sequences.
CLDR_DERIVED_URL = ("https://raw.githubusercontent.com/unicode-org/cldr-json/{v}/cldr-json/"
                    "cldr-annotations-derived-full/annotationsDerived/{lang}/annotations.json")
CLDR_DERIVED_SHA256 = {
    "en": "8ebc16e27adf6c555c9ce467335cee8fc9416e5d8646a91bd4eacbb450ebee22",
    "es": "0916ceedfd358fc0c6a04c410f04d21732736638443676da4405c7c17390e97b",
}

# Unicode group -> the keyboard's category; categories are written in this order
CATEGORIES = {
    "Smileys & Emotion": "smileys",
    "People & Body": "smileys",
    "Animals & Nature": "animals",
    "Food & Drink": "food",
    "Activities": "activity",
    "Travel & Places": "travel",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}
ORDER = ["smileys", "animals", "food", "activity", "travel", "objects", "symbols", "flags"]
TONES = [chr(c) for c in range(0x1F3FB, 0x1F400)]


def fetch(url: str = URL, sha256: str = SHA256) -> str:
    data = urllib.request.urlopen(url, timeout=60).read()
    got = hashlib.sha256(data).hexdigest()
    if got != sha256:
        sys.exit(f"{url}: sha256 {got}, expected {sha256}")
    return data.decode("utf-8")


def strip(e: str) -> str:
    """The emoji with its skin tones and presentation selectors taken out, as CLDR keys and Emoji.family do."""
    return "".join(ch for ch in e if ch not in TONES and ch != "\ufe0f")


def fold(word: str) -> str:
    """What v2t's letter keys type: lowercase, accents and ñ folded to their base letter."""
    d = unicodedata.normalize("NFD", word.lower())
    return "".join(ch for ch in d if not unicodedata.combining(ch)).strip()


def keywords(cats: dict[str, list[list[str]]], lang: str) -> list[str]:
    order = [item[0] for c in ORDER for item in cats[c]]
    rank = {e: i for i, e in enumerate(order)}
    by_strip = {strip(e): e for e in order}
    names: dict[str, set[str]] = {e: set() for e in order}  # each emoji's folded names in this language
    index: dict[str, set[str]] = {}
    sources = [(CLDR_URL.format(v=CLDR, lang=lang), CLDR_SHA256[lang], "annotations"),
               (CLDR_DERIVED_URL.format(v=CLDR, lang=lang), CLDR_DERIVED_SHA256[lang], "annotationsDerived")]
    for url, sha, top in sources:
        ann = json.loads(fetch(url, sha))[top]["annotations"]
        for key, a in ann.items():
            e = by_strip.get(strip(key))
            if e is None:
                continue
            # "flag: Spain" is also named "Spain", and found by it
            tts = [t for name in a.get("tts", []) for t in [name] + name.split(": ")[1:]]
            for name in tts:
                names[e].add(fold(name))
            for kw in a.get("default", []) + tts:
                k = fold(kw)
                if k and "\t" not in k and not k.startswith("#"):  # "#" starts a comment line
                    index.setdefault(k, set()).add(e)

    def order_for(k: str, e: str) -> tuple[int, int]:
        if k in names[e]:
            return (0, rank[e])
        if any(k in n.split() for n in names[e]):
            return (1, rank[e])
        return (2, rank[e])

    return [k + "\t" + " ".join(sorted(index[k], key=lambda e: order_for(k, e)))
            for k in sorted(index, key=lambda k: k.encode("utf-8"))]


def parse(text: str) -> dict[str, list[list[str]]]:
    """Category -> emoji in order, each as [base, *same-tone variants]."""
    entries: list[tuple[str, str]] = []  # (category, emoji), fully-qualified only
    group = None
    for line in text.splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if not line or line.startswith("#"):
            continue
        fields, _, _ = line.partition("#")
        codes, _, status = fields.partition(";")
        if status.strip() != "fully-qualified" or group not in CATEGORIES:
            continue
        entries.append((CATEGORIES[group], "".join(chr(int(c, 16)) for c in codes.split())))

    def key(e: str) -> str:  # the emoji with its skin tones and presentation selectors taken out
        return "".join(ch for ch in e if ch not in TONES and ch != "\ufe0f")

    out: dict[str, list[list[str]]] = {c: [] for c in ORDER}
    by_key: dict[str, list[str]] = {}
    for cat, e in entries:
        tones = {ch for ch in e if ch in TONES}
        if not tones:
            item = [e]
            out[cat].append(item)
            by_key.setdefault(key(e), item)
        elif len(tones) == 1 and (base := by_key.get(key(e))) is not None:
            tone = TONES.index(tones.pop())
            if len(base) - 1 == tone:  # the first variant of each tone, in tone order
                base.append(e)
    for items in out.values():
        for item in items:
            if len(item) not in (1, 6):
                sys.exit(f"{item[0]}: {len(item) - 1} skin tones, expected 0 or 5")
    return out


def main() -> None:
    cats = parse(fetch())
    lines = [
        f"# The emoji panel's data, generated by ios/tools/build_emoji.py from Unicode emoji-test.txt {VERSION}",
        f"# (sha256 {SHA256}). Do not edit by hand.",
        "# © 2024 Unicode, Inc. Unicode License v3; see ios/THIRD_PARTY_NOTICES.md.",
    ]
    for cat in ORDER:
        lines.append(f"@{cat}")
        lines += [",".join(item) for item in cats[cat]]
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    total = sum(len(v) for v in cats.values())
    toned = sum(1 for v in cats.values() for i in v if len(i) > 1)
    print(f"{OUT}: {total} emoji, {toned} with skin tones")
    for lang in LANGS:
        kw = keywords(cats, lang)
        head = [
            "# The emoji panel's search and suggestion keywords, generated by ios/tools/build_emoji.py from Unicode CLDR",
            f"# {CLDR} {lang} emoji annotations and derived annotations. Do not edit by hand.",
            "# © 2015-2024 Unicode, Inc. Unicode License v3; see ios/THIRD_PARTY_NOTICES.md.",
        ]
        keywords_out(lang).write_text("\n".join(head + kw) + "\n", encoding="utf-8")
        print(f"{keywords_out(lang)}: {len(kw)} keywords")


if __name__ == "__main__":
    main()
