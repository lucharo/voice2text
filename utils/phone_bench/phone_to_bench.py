#!/usr/bin/env python3
"""Hand a phone cleanup job's rows to the Mac scorers: each item gets the app's guards (the token cap, the
casual length guard, keep_spoken_words, then the dictionary's replacements) and is written as a
cleanup_bench row, so cleanup_eval.py and cleanup_judge.py score the phone's models beside the Mac's.

    .venv/bin/python utils/phone_bench/phone_to_bench.py q08-v-afm afm phone-apple-fm

Reads ~/.v2t/eval/phone-jobs/<job>/<job>.<arm>.jsonl (rows need chunk_in, chunk_out and chunk_s: arms run
with a `prompt` file write them), and writes <model folder>/<set>/parakeet-v3.jsonl under
~/.v2t/eval/grid/cleanup-models (or cleanup-wispr for ids starting wispr/).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / "utils/asr_grid"), str(REPO), str(Path(__file__).parent)]
import cleanup_bench as cb  # noqa: E402
import grid  # noqa: E402
import phone_common  # noqa: E402
from v2t import backends, config  # noqa: E402


def guarded(ins: list[str], outs: list[str], limited: list[bool], vocabulary) -> tuple[str, dict]:
    """The app's guards per chunk: a chunk that hit its token cap, came back empty or out of bounds keeps
    the words as heard; the rest are held to the spoken words."""
    parts, stats = [], {"chunks": len(ins), "guarded": 0, "limited": 0}
    for chunk, out, lim in zip(ins, outs, limited):
        out = (out or "").strip()
        if lim:
            stats["limited"] += 1
            parts.append(chunk)
        elif not out or not backends.within_length_guard(chunk, out, "casual"):
            stats["guarded"] += 1
            parts.append(chunk)
        else:
            parts.append(backends.keep_spoken_words(chunk, out, vocabulary)[0])
    return " ".join(parts).strip(), stats


def convert(job: str, arm: str, name: str) -> dict[str, list[dict]]:
    vocabulary, replacements = config.read_dictionary()
    rows = [r for r in phone_common.read_rows(grid.EVAL / "phone-jobs" / job / f"{job}.{arm}.jsonl")
            if r.get("event") == "clean"]
    if not rows:
        raise SystemExit(f"no cleanup rows in {job}.{arm}.jsonl")
    # an item that failed on the phone has no chunks to score; leaving it out would hide the failure
    if failed := [r["id"] for r in rows if "chunk_in" not in r]:
        raise SystemExit(f"{len(failed)} items have no chunk_in (failed on the phone, or an arm without a prompt "
                         f"file), e.g. {failed[0]}: rerun them first")
    by_set: dict[str, list[dict]] = {}
    for r in rows:
        ins, outs = r["chunk_in"], r["chunk_out"]
        clean, stats = guarded(ins, outs, r.get("chunk_limited", [False] * len(ins)), vocabulary)
        set_name, cid = r["id"].split("/", 1)
        by_set.setdefault(set_name, []).append({
            "id": cid, "raw": " ".join(ins), "model": " ".join(outs),
            "clean": config.apply_replacements(clean, replacements),
            "seconds": sum(r["chunk_s"]), "stats": stats, "thermal": r.get("thermal")})
    # a folder holds one export: refuse to mix it with another job, arm or dictionary under the same name
    import hashlib
    source = {"model": name, "source": f"phone job {job}, arm {arm}",
              "dictionary": hashlib.sha256(json.dumps([list(vocabulary), [list(x) for x in replacements]]).encode()).hexdigest()[:16]}
    for root in {cb.WISPR_MODELS if s == cb.WISPR else cb.MODELS for s in by_set}:
        cfg = root / name / "config.json"
        if cfg.exists() and json.loads(cfg.read_text()) != source:
            raise SystemExit(f"{root / name} holds another export ({cfg.read_text().strip()}): use another name or move it aside")
        if not cfg.exists() and any((root / name).glob("*/*.jsonl")):
            raise SystemExit(f"{root / name} holds results with no record of what made them: move it aside first")
    for set_name, out in by_set.items():
        root = cb.WISPR_MODELS if set_name == cb.WISPR else cb.MODELS
        # the record first, so a stop half way leaves results that say where they came from
        grid.private_dir(root / name)
        (root / name / "config.json").write_text(json.dumps(source) + "\n")
        path = grid.private_dir(root / name / set_name) / "parakeet-v3.jsonl"
        path.write_text("".join(json.dumps(x) + "\n" for x in out))
    return by_set


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    for set_name, out in convert(*sys.argv[1:4]).items():
        print(f"{set_name}: {len(out)} items, {sum(x['stats']['guarded'] + x['stats']['limited'] for x in out)} reverted")


if __name__ == "__main__":
    main()
