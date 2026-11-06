#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyarrow==26.0.1"]
# ///
"""Fetch the real-misspelling and correct-text sets the keyboard's autocorrect is measured on, at pinned
revisions, and write them as plain files for `swift test --filter RealTypoEval`. Not committed; ios/setup.sh
runs this.

    uv run tools/fetch_misspellings.py <out-dir>

Sources (see ios/THIRD_PARTY_NOTICES.md):
- English misspellings: Wikipedia's "Lists of common misspellings/For machines" (misspellings Wikipedia editors
  actually made), CC BY-SA 4.0, revision 1199637275.
- Spanish misspellings: Spanish Wikipedia's "Corrector ortográfico/Listado" (the list its spelling bots fix),
  CC BY-SA 4.0, revision 176131402. Case-only entries (`cs`) and entries whose first suggestion is the term
  itself (real words that are usually right) are left out.
- Correct text: every 200th Tatoeba sentence of the pinned English-Spanish pairs build_lexicons.py uses for its
  bigrams (CC BY 2.0 FR), so about 1,000 sentences a language. They also fed the bigram counts, which only
  makes the next-word context a little kinder on them than on unseen text.

Outputs: <lang>.tsv (misspelling TAB target[,target...]) and <lang>-sentences.txt (one sentence a line).
"""
import hashlib
import io
import re
import sys
import urllib.request
from pathlib import Path

BUILD = 1  # bump when the output changes for the same inputs
UA = {"User-Agent": "voice2text-keyboard-eval/1.0 (https://github.com/lucharo/voice2text)"}
SOURCES = {
    "en": ("https://en.wikipedia.org/w/index.php?title=Wikipedia:Lists_of_common_misspellings/For_machines"
           "&action=raw&oldid=1199637275",
           "3b6a9290e5aaad968da7ec769a5174adb45247688ef7ae097fd2dd80237a3050"),
    "es": ("https://es.wikipedia.org/w/index.php?title=Wikipedia:Corrector_ortogr%C3%A1fico/Listado"
           "&action=raw&oldid=176131402",
           "16292ce16e8d3a1ae206717b7b061422cbd9ce2b3b295e44f99f4d398621df0c"),
}
TATOEBA_REV = "cec1343ab5a7a8befe99af4a2d0ca847b6c84743"
TATOEBA_URL = ("https://huggingface.co/datasets/sentence-transformers/parallel-sentences-tatoeba/resolve/"
               f"{TATOEBA_REV}/en-es/train-00000-of-00001.parquet")
TATOEBA_SHA = "b62747cc931b16ec95f265b37e3328c0ea9f211c2e0eb3ceb309d5932af37448"
TATOEBA_COLUMN = {"en": "english", "es": "non_english"}
SENTENCE_STRIDE = 200
WORD = re.compile(r"^[^\W\d_]+$")


def fetch(url: str, sha: str) -> bytes:
    data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120).read()
    got = hashlib.sha256(data).hexdigest()
    if got != sha:
        sys.exit(f"{url}: sha256 {got}, expected {sha}")
    return data


def english(text: str) -> list[tuple[str, list[str]]]:
    out = []
    for line in text.splitlines():
        if "->" not in line:
            continue
        typo, targets = line.strip().split("->", 1)
        targets = [t.strip() for t in targets.split(",") if t.strip()]
        if WORD.match(typo) and targets and all(WORD.match(t) for t in targets):
            out.append((typo, targets))
    return out


def split_alternatives(s: str) -> list[str]:
    """'actuó (verbo, 3.ª persona), actúo (verbo)' -> ['actuó', 'actúo']"""
    parts, depth, cur = [], 0, ""
    for ch in s:
        depth += (ch == "(") - (ch == ")")
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return [re.sub(r"\(.*?\)", "", p).strip() for p in parts if p.strip()]


def spanish(text: str) -> list[tuple[str, list[str]]]:
    out = []
    for line in text.splitlines():
        if not line.startswith(" ") or line.count("|") < 2:
            continue
        term, param, alts = line[1:].split("|", 2)
        if param.strip() == "cs" or not WORD.match(term):
            continue
        targets = [t for t in split_alternatives(alts) if WORD.match(t)]
        if not targets or targets[0].lower() == term.lower():
            continue
        out.append((term, [t for t in targets if t.lower() != term.lower()]))
    return out


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/misspellings")
    stamp = out / "stamp"
    want = f"{BUILD} {SOURCES} {TATOEBA_SHA} {SENTENCE_STRIDE}"
    if stamp.exists() and stamp.read_text() == want:
        return
    out.mkdir(parents=True, exist_ok=True)
    for lang, parse in (("en", english), ("es", spanish)):
        url, sha = SOURCES[lang]
        rows = parse(fetch(url, sha).decode("utf-8"))
        (out / f"{lang}.tsv").write_text("".join(f"{t}\t{','.join(ts)}\n" for t, ts in rows))
        print(f"{out}/{lang}.tsv: {len(rows)} misspellings")
    import pyarrow.parquet as pq
    table = pq.read_table(io.BytesIO(fetch(TATOEBA_URL, TATOEBA_SHA)))
    for lang, column in TATOEBA_COLUMN.items():
        sentences = [s.strip() for s in table.column(column).to_pylist()[::SENTENCE_STRIDE] if s and "\n" not in s]
        (out / f"{lang}-sentences.txt").write_text("\n".join(sentences) + "\n")
        print(f"{out}/{lang}-sentences.txt: {len(sentences)} sentences")
    stamp.write_text(want)


if __name__ == "__main__":
    main()
