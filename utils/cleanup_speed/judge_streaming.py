"""Does cleaning settled sentences while recording change how good the cleanup is?

Maintainer-only, and it costs money: utils/asr_grid/cleanup_judge.py's judge (gpt-6.1-sol on Azure,
AZURE_OPENAI_API_KEY) scores the batch and streaming texts that bench_streaming.py wrote to
``~/.v2t/eval/cleanup-stream/results.jsonl``, beside each dictation's raw transcript from history,
shuffled and unlabelled, on the same five criteria. Dictations whose two texts are identical tie by
definition and are not sent.

    uv run python utils/cleanup_speed/judge_streaming.py

Judgments are cached in ``judgments.jsonl`` beside the results, so a rerun pays only for new texts.
"""

from __future__ import annotations

import json
import random
import sqlite3
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "asr_grid"))
import cleanup_judge as cj  # noqa: E402

DIR = Path.home() / ".v2t/eval/cleanup-stream"
HISTORY = Path.home() / ".v2t/history/history.sqlite"
ARMS = ("batch", "stream")


def main() -> int:
    results = [json.loads(line) for line in (DIR / "results.jsonl").read_text().splitlines() if line]
    con = sqlite3.connect(f"file:{HISTORY}?mode=ro", uri=True)
    raw = dict(con.execute("select id, raw from transcriptions"))
    con.close()
    path = DIR / "judgments.jsonl"
    cached = {}  # judgment key -> {"texts": {text_id: scores}, "best": text_id}
    if path.exists():
        rows = (json.loads(line) for line in path.read_text().splitlines() if line)
        cached = {r["key"]: r for r in rows if "texts" in r}
    key, spent = cj.azure_key(), 0.0
    identical = sum(r["identical"] for r in results)
    judged, rejected = [], 0  # judged: (batch scores, stream scores, best arm)
    with path.open("a") as f:
        for r in results:
            if r["identical"]:
                continue
            texts = {"batch": r["batch_text"], "stream": r["stream_text"]}
            k = cj.judgment_key("history-stream", str(r["id"]), raw[r["id"]], sorted(texts.values()))
            if k not in cached:
                order = random.Random(k).sample(ARMS, 2)  # shuffled, the same on a rerun
                labels = ["A", "B"]
                grades, usage = cj.ask(key, raw[r["id"]], [(lab, texts[a]) for lab, a in zip(labels, order)])
                spent += cj.cost(usage)
                problem = cj.check(grades, labels)
                if problem:
                    print(f"id {r['id']}: reply not used ({problem})")
                    rejected += 1
                    continue
                by_label = {g["label"]: {c: g[c] for c in cj.CRITERIA} for g in grades["versions"]}
                text_of = {lab: texts[a] for lab, a in zip(labels, order)}
                # kept per text, as cleanup_judge does, so a rerun maps scores to whichever arm has the text now
                cached[k] = {
                    "key": k, "id": r["id"], "model": cj.MODEL,
                    "texts": {cj.text_id(text_of[lab]): scores for lab, scores in by_label.items()},
                    "best": cj.text_id(text_of[grades["best"]]),
                }
                f.write(json.dumps(cached[k]) + "\n")
                f.flush()
            j = cached[k]
            b, s_ = cj.text_id(texts["batch"]), cj.text_id(texts["stream"])
            judged.append((j["texts"][b], j["texts"][s_], "stream" if j["best"] == s_ else "batch"))
    path.chmod(0o600)

    differ = len(results) - identical
    lines = [
        f"{differ} of {len(results)} dictations differ between batch and streaming cleanup "
        f"({identical} identical, not sent); {len(judged)} judged, {rejected} replies not used; "
        f"judge {cj.MODEL}, ${spent:.2f} this run.",
    ]
    if judged:
        lines += [
            "",
            "| criterion | batch mean | streaming mean | streaming higher / lower / same |",
            "|---|--:|--:|--:|",
        ]
        for c in (*cj.CRITERIA, "all"):
            def score(scores):
                return statistics.fmean(scores.values()) if c == "all" else scores[c]
            b = [score(x) for x, _y, _w in judged]
            s = [score(y) for _x, y, _w in judged]
            higher = sum(y > x for x, y in zip(b, s))
            lower = sum(y < x for x, y in zip(b, s))
            lines.append(
                f"| {c} | {statistics.fmean(b):.2f} | {statistics.fmean(s):.2f} | "
                f"{higher} / {lower} / {len(judged) - higher - lower} |"
            )
        wins = sum(w == "stream" for _x, _y, w in judged)
        lines += ["", f"Judge would rather paste: streaming {wins}, batch {len(judged) - wins}."]
    (DIR / "judge-report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
