"""Silver transcripts for the `wispr` set, and a scorer for cleanup variants against them.

Maintainer-only. The `wispr` dictations have no ground truth. A 2026-10-24 read-through
of all 208 found Wispr Flow's API, Cohere and Qwen3-ASR the most plausible, so the
silver transcript of a clip is the medoid of those three systems' texts: the one the
other two agree with most. Cohere is taken with its silence trimmed
(`cohere-transcribe-vad`), since it loops on silence otherwise.

    python silver.py build                          # -> ~/.v2t/eval/grid/silver/wispr.jsonl
    python silver.py score FILE.jsonl --field F     # WER of each row's F against silver
    python silver.py score FILE.jsonl --field F --ids held-out

Scores are word error rates counted the Open ASR Leaderboard's way (grid.normalise and its
compound-merging alignment), so punctuation, casing and split compounds do not count; they split into missing words (deletions: content cut), extra words
(insertions: content invented) and substitutions. A score against silver measures
closeness to the best available systems, not correctness.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import grid

VOTERS = ("wispr-flow-api", "cohere-transcribe-vad", "qwen3-asr-1.7b")
SILVER = grid.GRID / "silver"


def build() -> Path:
    clips = {c["id"]: c for c in grid.read_jsonl(grid.SETS / "wispr.jsonl")}
    cells = {}
    for s in VOTERS:
        rows = {r["id"]: r for r in grid.read_jsonl(grid.RESULTS / "wispr" / f"{s}.jsonl")}
        if missing := set(clips) - set(rows):
            raise SystemExit(f"{s}: {len(missing)} of {len(clips)} clips missing; run its cell first")
        cells[s] = rows
    out = grid.private_dir(SILVER) / "wispr.jsonl"
    tmp = out.with_suffix(".jsonl.tmp")
    picks: dict[str, int] = dict.fromkeys(VOTERS, 0)
    with tmp.open("w") as f:
        for cid, clip in clips.items():
            texts = {s: grid.final_text(s, cells[s][cid]) for s in VOTERS}
            words = {s: grid.normalise(t, "en") for s, t in texts.items()}
            best = min(VOTERS, key=lambda s: sum(grid.edits(words[s], words[o]) for o in VOTERS if o != s))
            picks[best] += 1
            f.write(json.dumps({"id": cid, "duration_s": clip["duration_s"], "from": best, "text": texts[best]}) + "\n")
    tmp.chmod(0o600)
    tmp.replace(out)  # only a complete build replaces the old one
    print(f"{len(clips)} silver transcripts -> {out}; picked from {picks}")
    return out


def held_out(cid: str) -> bool:
    """A fixed third of the clips, by id hash: tune on the rest, report on these."""
    return int(hashlib.sha256(cid.encode()).hexdigest(), 16) % 3 == 0


def score(path: Path, field: str, ids: str = "all") -> dict:
    from kaldialign import edit_distance

    silver = {r["id"]: r for r in grid.read_jsonl(SILVER / "wispr.jsonl")}
    rows = grid.read_jsonl(path)
    totals = {"ref": 0, "del": 0, "ins": 0, "sub": 0, "clips": 0}
    for r in rows:
        # full ids, or short ones that match exactly one clip
        matches = [r["id"]] if r["id"] in silver else [k for k in silver if k.startswith(r["id"])]
        if len(matches) > 1:
            raise SystemExit(f"id {r['id']} matches {len(matches)} silver clips")
        cid = matches[0] if matches else None
        if cid is None or r.get(field) is None:
            continue
        if ids != "all" and held_out(cid) != (ids == "held-out"):
            continue
        ref = grid.normalise(silver[cid]["text"], "en")
        hyp = grid.normalise(r[field], "en")
        counts = edit_distance(tuple(ref), tuple(hyp), merge_compounds=True)  # as grid.edits
        totals["ref"] += len(ref)
        totals["clips"] += 1
        for key in ("del", "ins", "sub"):
            totals[key] += counts[key]
    if not totals["clips"] or not totals["ref"]:
        raise SystemExit(f"{field}: no clips scored; check the path, --field and that `silver.py build` ran")
    n = totals["ref"]
    result = {
        "field": field, "clips": totals["clips"],
        "wer": (totals["del"] + totals["ins"] + totals["sub"]) / n,
        "missing": totals["del"] / n, "extra": totals["ins"] / n, "substituted": totals["sub"] / n,
    }
    print(
        f"{field:28} {result['clips']:4} clips  WER {100 * result['wer']:5.2f}%  "
        f"missing {100 * result['missing']:5.2f}%  extra {100 * result['extra']:5.2f}%  "
        f"substituted {100 * result['substituted']:5.2f}%"
    )
    return result


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("build")
    s = sub.add_parser("score")
    s.add_argument("path", type=Path)
    s.add_argument("--field", action="append", required=True)
    s.add_argument("--ids", choices=["all", "tune", "held-out"], default="all")
    a = p.parse_args(argv)
    if a.command == "build":
        build()
    else:
        for field in a.field:
            score(a.path, field, a.ids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
