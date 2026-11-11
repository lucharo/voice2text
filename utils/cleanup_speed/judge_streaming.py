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
    cached = {}
    if path.exists():
        cached = {r["key"]: r for r in map(json.loads, path.read_text().splitlines()) if r}
    key, spent = cj.azure_key(), 0.0
    judged = []
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
                    continue
                by_label = {g["label"]: {c: g[c] for c in cj.CRITERIA} for g in grades["versions"]}
                cached[k] = {
                    "key": k, "id": r["id"], "model": cj.MODEL,
                    "scores": {a: by_label[lab] for lab, a in zip(labels, order)},
                    "best": dict(zip(labels, order))[grades["best"]],
                }
                f.write(json.dumps(cached[k]) + "\n")
                f.flush()
            judged.append(cached[k])
    path.chmod(0o600)

    lines = [
        f"{len(judged)} of {len(results)} dictations differ between batch and streaming cleanup "
        f"({len(results) - len(judged)} identical, not sent); judge {cj.MODEL}, ${spent:.2f} this run.",
        "",
        "| criterion | batch mean | streaming mean | streaming higher / lower / same |",
        "|---|--:|--:|--:|",
    ]
    for c in (*cj.CRITERIA, "all"):
        def score(j, arm):
            s = j["scores"][arm]
            return statistics.fmean(s.values()) if c == "all" else s[c]
        b = [score(j, "batch") for j in judged]
        s = [score(j, "stream") for j in judged]
        higher = sum(y > x for x, y in zip(b, s))
        lower = sum(y < x for x, y in zip(b, s))
        lines.append(
            f"| {c} | {statistics.fmean(b):.2f} | {statistics.fmean(s):.2f} | "
            f"{higher} / {lower} / {len(judged) - higher - lower} |"
        )
    wins = sum(j["best"] == "stream" for j in judged)
    lines += ["", f"Judge would rather paste: streaming {wins}, batch {len(judged) - wins}."]
    (DIR / "judge-report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
