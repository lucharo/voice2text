"""Score cleanup on formatting, the part plain WER cannot see: punctuation, capitals, fillers, repeats, digits.

Maintainer-only. Reads the rows cleanup_bench.py wrote (raw transcript, model text, guarded text) and
scores each against a formatted reference, word by word:

- punctuation: after each word the reference and the output agree on, which mark follows it (none,
  comma, full stop, question mark, ...): precision, recall and F1 per mark and over all marks, as
  LibriSpeech-PC scores punctuation
- capitals: whether those words start with a capital in both (F1 on "capitalised")
- fillers left: um, uh and friends in the output, against the raw transcript
- repeats left: a word said twice in a row ("the the"), against the raw transcript
- digits: of the numbers the reference writes in digits, how many the output writes the same way

References: Earnings22's own transcripts, LibriSpeech-PC (NVIDIA's punctuated LibriSpeech, openslr.org/145,
unpacked into ~/.v2t/eval/cleanup-eval/librispeech-pc), and on the maintainer's dictations Wispr Flow's
formatted text, a point of comparison and not ground truth (its terms allow scoring against it, not
tuning on it).

    .venv/bin/python utils/asr_grid/cleanup_eval.py
"""

from __future__ import annotations

import collections
import difflib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cleanup_bench as cb
import grid

PC = grid.EVAL / "cleanup-eval" / "librispeech-pc"
FILLERS = frozenset({"um", "uh", "erm", "er", "uhm", "hmm", "mm", "ah"})
MARKS = (",", ".", "?", "!", ":", ";")
_WORD = re.compile(r"[\w'’]+(?:[-.][\w'’]+)*")
_TOKEN = re.compile(r"[\w'’]+(?:[-.][\w'’]+)*|[^\w\s]")


def _bare(w: str) -> str:
    return w.lower().replace("’", "'")


def tokens(text: str) -> list[tuple[str, str]]:
    """(word, the punctuation mark right after it or ''), skipping marks that follow no word."""
    out: list[list[str]] = []
    for t in _TOKEN.findall(text or ""):
        if _WORD.fullmatch(t):
            out.append([t, ""])
        elif out and t in MARKS and not out[-1][1]:
            out[-1][1] = t
    return [(w, m) for w, m in out]


def compare(ref: str, hyp: str) -> collections.Counter:
    """Counts for one pair, on the words both have (aligned on lowercase words)."""
    r, h = tokens(ref), tokens(hyp)
    sm = difflib.SequenceMatcher(a=[_bare(w) for w, _ in r], b=[_bare(w) for w, _ in h], autojunk=False)
    c = collections.Counter()
    for i, j, n in sm.get_matching_blocks():
        for k in range(n):
            (rw, rm), (hw, hm) = r[i + k], h[j + k]
            c["matched"] += 1
            # punctuation: true positive when the same mark follows; a wrong mark is both a miss and a false alarm
            for mark in MARKS:
                c[f"tp{mark}"] += rm == hm == mark
                c[f"fn{mark}"] += rm == mark and hm != mark
                c[f"fp{mark}"] += hm == mark and rm != mark
            ru, hu = rw[:1].isupper(), hw[:1].isupper()
            c["cap_tp"] += ru and hu
            c["cap_fn"] += ru and not hu
            c["cap_fp"] += hu and not ru
    digits = [w for w, _ in r if any(ch.isdigit() for ch in w)]
    hyp_words = collections.Counter(_bare(w) for w, _ in h)
    c["digits_ref"] += len(digits)
    for d in digits:
        if hyp_words[_bare(d)] > 0:
            c["digits_hit"] += 1
            hyp_words[_bare(d)] -= 1
    return c


def leftovers(raw: str, out: str) -> collections.Counter:
    """Fillers and immediate repeats in the raw transcript and in the output."""
    c = collections.Counter()
    for key, text in (("raw", raw), ("out", out)):
        words = [_bare(w) for w, _ in tokens(text)]
        c[f"fill_{key}"] += sum(w in FILLERS for w in words)
        c[f"rep_{key}"] += sum(a == b and a not in FILLERS for a, b in zip(words, words[1:]))
    return c


def f1(tp: int, fp: int, fn: int) -> float:
    return 2 * tp / max(2 * tp + fp + fn, 1)


def summary(c: collections.Counter) -> dict:
    tp, fp, fn = (sum(c[f"{k}{m}"] for m in MARKS) for k in ("tp", "fp", "fn"))
    return {
        "punct_f1": 100 * f1(tp, fp, fn),
        "comma_f1": 100 * f1(c["tp,"], c["fp,"], c["fn,"]),
        "stop_f1": 100 * f1(c["tp."], c["fp."], c["fn."]),
        "question_f1": 100 * f1(c["tp?"], c["fp?"], c["fn?"]),
        "cap_f1": 100 * f1(c["cap_tp"], c["cap_fp"], c["cap_fn"]),
        "digits": 100 * c["digits_hit"] / c["digits_ref"] if c["digits_ref"] else None,
        "fillers_left": 100 * c["fill_out"] / c["fill_raw"] if c["fill_raw"] else None,
        "repeats_left": 100 * c["rep_out"] / c["rep_raw"] if c["rep_raw"] else None,
    }


def references() -> dict[str, dict[str, str]]:
    refs = {"earnings22": {c["id"]: c["text"] for c in grid.read_jsonl(grid.SETS / "earnings22.jsonl")}}
    for s, f in (("ls-clean", "test-clean"), ("ls-other", "test-other")):
        if (PC / f"{f}.json").exists():
            refs[s] = {(d := json.loads(line))["audio_filepath"].rsplit("/", 1)[1].rsplit(".", 1)[0]: d["text"]
                       for line in (PC / f"{f}.json").read_text().splitlines() if line.strip()}
    if cb.WISPR_REFS.exists():
        refs[cb.WISPR] = {r["id"]: r["wispr_formatted"] for r in grid.read_jsonl(cb.WISPR_REFS)
                          if r.get("wispr_formatted") and not r.get("wispr_cut")}
    return refs


def main() -> None:
    refs = references()
    system = "parakeet-v3"
    cols = ("punct_f1", "comma_f1", "stop_f1", "question_f1", "cap_f1", "digits", "fillers_left", "repeats_left")
    for set_name, ref in refs.items():
        root = cb.WISPR_MODELS if set_name == cb.WISPR else cb.MODELS
        names = sorted(p.parent.parent.name for p in root.glob(f"*/{set_name}/{system}.jsonl"))
        if not names:
            continue
        data = {n: {r["id"]: r for r in grid.read_jsonl(root / n / set_name / f"{system}.jsonl")} for n in names}
        ids = sorted(set(ref).intersection(*(set(d) for d in data.values())))
        print(f"\n{set_name}: {len(ids)} clips against {'Wispr Flow' if set_name == cb.WISPR else 'the reference'}")
        print("| output | " + " | ".join(cols) + " |")
        print("|---|" + "--:|" * len(cols))
        variants = [("raw transcript", names[0], "raw")] + [(f"{n} {k}", n, k) for n in names for k in ("model", "clean")]
        for label, n, key in variants:
            c = collections.Counter()
            for i in ids:
                row = data[n][i]
                c += compare(ref[i], row[key])
                c += leftovers(row["raw"], row[key])
            s = summary(c)
            print(f"| {label.replace(' clean', ' guarded')} | " + " | ".join("–" if s[k] is None else f"{s[k]:.1f}" for k in cols) + " |")


if __name__ == "__main__":
    main()
