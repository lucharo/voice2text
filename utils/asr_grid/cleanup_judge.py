"""An LLM judge for dictation cleanup: how well each output formats what was said without changing it.

Maintainer-only, and it costs money: each call goes to one fixed model on GSK's Azure OpenAI (gpt-6.1-sol,
about $2 per million input tokens and $10 per million output). Every output of one clip goes in a single
call, shuffled and unlabelled, beside the raw transcript, so the judge compares them on the same text.

It scores the edits Wispr Flow's cleanup makes beyond a raw transcript (per 1,000 words on the maintainer's
dictations: 64 punctuation edits, 47 capitals, 32 fillers removed, 3 repeats, 1 number in digits), 1 to 5:

- punctuation: commas, full stops, question marks and sentence breaks where a careful writer puts them
- capitals: sentence starts, names and acronyms
- fillers: um, uh and false starts or repeats removed where they carry nothing
- numbers: numbers written as digits where a reader expects them
- faithful: every spoken word that carries meaning kept, nothing added, nothing answered

and picks the output it would rather paste. Wispr's text is never shown to the judge (its terms allow
scoring against it, not tuning on it, #122).

    .venv/bin/python utils/asr_grid/cleanup_judge.py run --budget 5      # dollars; resumable
    .venv/bin/python utils/asr_grid/cleanup_judge.py report

Outputs come from cleanup_bench.py's rows (`--cleanup` runs, guarded text as pasted) plus the iPhone's Apple
Intelligence run from #67 on Earnings22. Judgments are cached per clip and set of outputs in
~/.v2t/eval/cleanup-judge/judgments.jsonl, so a rerun only pays for what changed. The key is
AZURE_OPENAI_API_KEY from the environment (jules-aiml-2's).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import statistics
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cleanup_bench as cb
import grid

OUT = grid.EVAL / "cleanup-judge"
MODEL = "gpt-6.1-sol"
ENDPOINT = "https://jules-aiml-2.openai.azure.com/openai/v1/responses"
PRICE = (2.0, 10.0)  # dollars per million input and output tokens, gsk-llms ls azure_openai (2026-11-07)
AFM_PHONE = grid.EVAL / "iphone-2026-10-27" / "cleanup-afm-wrap.jsonl"
CRITERIA = ("punctuation", "capitals", "fillers", "numbers", "faithful")
SETS = ("earnings22", cb.WISPR)

INSTRUCTIONS = """You grade cleanups of dictated speech. You get the raw speech-to-text transcript of one
dictation and several cleaned versions of it, labelled A, B, C and so on, in no particular order. A good
cleanup reads as the speaker's own words written down with care: correct punctuation and sentence breaks,
capitals where they belong, the fillers um and uh and stumbles such as repeated words removed, numbers as
digits where a reader expects them, and every word that carries meaning kept. It must not drop content,
add words the speaker did not say, rephrase, or answer the text. Score each version from 1 (bad) to 5
(as good as a careful human editor) on each criterion:
- punctuation: commas, full stops, question marks and sentence breaks
- capitals: sentence starts, names, acronyms
- fillers: um, uh, false starts and repeats removed where they carry nothing (5 if there were none)
- numbers: numbers written as digits where a reader expects them (5 if there were none)
- faithful: meaning-carrying words kept, nothing added, nothing answered
Versions can be identical; give identical versions identical scores. Then name the version you would
rather paste. Judge only from the text."""

SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["versions", "best"],
    "properties": {
        "versions": {"type": "array", "items": {
            "type": "object", "additionalProperties": False, "required": ["label", *CRITERIA],
            "properties": {"label": {"type": "string"}, **{c: {"type": "integer"} for c in CRITERIA}}}},
        "best": {"type": "string"},
    },
}


def outputs(set_name: str, system: str = "parakeet-v3") -> dict[str, dict[str, str]]:
    """Per clip id: {output name: text}. The raw transcript is one of them."""
    root = cb.WISPR_MODELS if set_name == cb.WISPR else cb.MODELS
    clips: dict[str, dict[str, str]] = {}
    for path in sorted(root.glob(f"*/{set_name}/{system}.jsonl")):
        name = path.parent.parent.name
        for r in grid.read_jsonl(path):
            clips.setdefault(r["id"], {"raw": r["raw"]})[name] = r["clean"]
    if set_name == "earnings22" and AFM_PHONE.exists():
        sys.path.insert(0, str(grid.REPO))
        from v2t import backends, config

        vocabulary, _ = config.read_dictionary()
        for r in map(json.loads, AFM_PHONE.read_text().splitlines()):
            cid = r.get("id", "").removeprefix("earnings22/")
            if r.get("event") != "clean" or cid not in clips:
                continue
            raw, out = clips[cid]["raw"], (r.get("clean") or "").strip()
            # the app's guards, as Cleaner.swift applies them per chunk (these clips are one chunk each)
            ok = out and backends.within_length_guard(raw, out, "casual")
            clips[cid]["apple-fm (iPhone)"] = backends.keep_spoken_words(raw, out, vocabulary)[0] if ok else raw
    return clips


def azure_key() -> str:
    key = os.environ.get("AZURE_OPENAI_API_KEY", "")
    if not key:
        raise SystemExit("AZURE_OPENAI_API_KEY is not set: it is jules-aiml-2's key")
    return key


def ask(key: str, raw: str, versions: list[tuple[str, str]]) -> tuple[dict, dict]:
    text = f"Raw transcript:\n{raw}\n\n" + "\n\n".join(f"Version {label}:\n{t}" for label, t in versions)
    body = {"model": MODEL, "instructions": INSTRUCTIONS, "input": text, "reasoning": {"effort": "low"},
            "max_output_tokens": 4000,
            "text": {"format": {"type": "json_schema", "name": "grades", "schema": SCHEMA, "strict": True}}}
    for attempt in range(4):
        req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(),
                                     headers={"api-key": key, "content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                data = json.loads(r.read())
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(10 * (attempt + 1))
                continue
            raise
    out = next(c["text"] for o in data["output"] if o["type"] == "message" for c in o["content"] if c["type"] == "output_text")
    return json.loads(out), data["usage"]


def cost(usage: dict) -> float:
    return (usage["input_tokens"] * PRICE[0] + usage["output_tokens"] * PRICE[1]) / 1e6


def text_id(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def judgment_key(set_name: str, cid: str, raw: str, distinct: list[str]) -> str:
    """What decides a judgment: the clip, the judge and its instructions, and the distinct texts it saw.
    Which model wrote which text is not part of it: scores are kept per text and given to the models
    at report time, from their current outputs."""
    return hashlib.sha256(json.dumps([set_name, cid, MODEL, INSTRUCTIONS, raw, distinct]).encode()).hexdigest()[:20]


def check(grades: dict, labels: list[str]) -> str | None:
    """Why a reply cannot be used, or None: every label scored once, 1 to 5, and a winner among them."""
    got = [g.get("label") for g in grades.get("versions", [])]
    if sorted(got) != sorted(labels):
        return f"labels {sorted(got)} for {sorted(labels)}"
    if any(not (isinstance(g.get(c), int) and 1 <= g[c] <= 5) for g in grades["versions"] for c in CRITERIA):
        return "a score outside 1-5"
    if grades.get("best") not in labels:
        return f"best {grades.get('best')!r} is not a label"
    return None


def worst_case(raw: str, distinct: list[str]) -> float:
    """An upper bound on one call's cost, about 3 characters a token, so a run stops before the budget."""
    chars = len(INSTRUCTIONS) + len(raw) + sum(len(t) + 20 for t in distinct)
    return (chars / 3 * PRICE[0] + 4000 * PRICE[1]) / 1e6


def run(args) -> None:
    path = grid.private_dir(OUT) / "judgments.jsonl"
    spend = grid.private_dir(OUT) / "spend.jsonl"  # every call, kept or not, for the bill
    done = {r["key"] for r in grid.read_jsonl(path)}
    spent = sum(r["usd"] for r in grid.read_jsonl(spend))
    print(f"already spent ${spent:.2f}; {len(done)} judgments")
    key, start = azure_key(), spent
    with path.open("a") as f, spend.open("a") as bill:
        for set_name in args.sets:
            clips = outputs(set_name)
            ids = sorted(clips)[: args.limit] if args.limit else sorted(clips)
            for cid in ids:
                outs = clips[cid]
                # identical texts are judged once: the judge sees each distinct cleanup a single time
                distinct = sorted({t for t in outs.values()})
                k = judgment_key(set_name, cid, outs["raw"], distinct)
                if k in done:
                    continue
                if spent - start + worst_case(outs["raw"], distinct) > args.budget:
                    print(f"the next call could pass the ${args.budget:.2f} budget; run again to continue")
                    return
                rng = random.Random(k)  # the order is shuffled, but the same on a rerun
                order = rng.sample(distinct, len(distinct))
                labels = [chr(ord("A") + i) for i in range(len(order))]
                grades, usage = ask(key, outs["raw"], list(zip(labels, order)))
                spent += cost(usage)
                problem = check(grades, labels)
                bill.write(json.dumps({"key": k, "usd": cost(usage), "usage": usage, "rejected": problem}) + "\n")
                bill.flush()
                if problem:  # not marked done, so the next run asks again
                    print(f"{set_name}/{cid}: reply not used ({problem})")
                    continue
                by_label = {g["label"]: {c: g[c] for c in CRITERIA} for g in grades["versions"]}
                row = {"key": k, "set": set_name, "id": cid, "model": MODEL,
                       "texts": {text_id(t): by_label[lab] for lab, t in zip(labels, order)},
                       "best": text_id(dict(zip(labels, order))[grades["best"]])}
                f.write(json.dumps(row) + "\n")
                f.flush()
                done.add(k)
    print(f"spent ${spent - start:.2f} this run, ${spent:.2f} in all")


def report(args) -> None:
    rows = {r["key"]: r for r in grid.read_jsonl(OUT / "judgments.jsonl")}
    if not rows:
        raise SystemExit(f"no judgments under {OUT}: run first")
    for set_name in args.sets:
        # only the judgment of each clip's current outputs; older ones stay in the file for the bill
        current = []
        for cid, outs in outputs(set_name).items():
            r = rows.get(judgment_key(set_name, cid, outs["raw"], sorted(set(outs.values()))))
            if r:
                current.append({n: (r["texts"][text_id(t)], text_id(t) == r["best"]) for n, t in outs.items()})
        if not current:
            continue
        names = sorted(set.intersection(*(set(c) for c in current)), key=lambda n: (n != "raw", n))
        print(f"\n{set_name}: {len(current)} clips judged by {MODEL}, scores 1-5 (mean), and how often each was the pick"
              " (identical outputs share a pick, so the column sums past 100%)")
        print("| output | " + " | ".join(CRITERIA) + " | mean | picked |")
        print("|---|" + "--:|" * (len(CRITERIA) + 2))
        for n in names:
            means = [statistics.fmean(c[n][0][k] for c in current) for k in CRITERIA]
            picked = sum(c[n][1] for c in current) / len(current)
            print(f"| {n} | " + " | ".join(f"{m:.2f}" for m in means) + f" | {statistics.fmean(means):.2f} | {100 * picked:.0f}% |")
        missing = len(outputs(set_name)) - len(current)
        if missing:
            print(f"({missing} clips not judged for their current outputs: run again)")
    bill = grid.read_jsonl(OUT / "spend.jsonl")
    print(f"\ncost so far: ${sum(r['usd'] for r in bill):.2f} over {len(bill)} calls")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("command", choices=("run", "report"))
    p.add_argument("--sets", nargs="+", default=list(SETS), choices=SETS)
    p.add_argument("--budget", type=float, default=5.0, help="run: dollars to spend at most this run (default 5)")
    p.add_argument("--limit", type=int, help="run: only the first N clips of each set")
    a = p.parse_args()
    {"run": run, "report": report}[a.command](a)


if __name__ == "__main__":
    main()
