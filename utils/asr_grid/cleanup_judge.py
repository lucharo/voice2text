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
~/.v2t/eval/cleanup-judge/judgments.jsonl, so a rerun only pays for what changed. The key is fetched
with `az` at run time (the one in the environment can be stale) and never written down.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import statistics
import subprocess
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
ACCOUNT = ("jules-aiml-2", "RD-jules-aiml-AppResources-devtest", "e2691b7e-8c09-48f0-a9db-0b55fb638d4a")
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
    name, group, sub = ACCOUNT
    key = subprocess.run(["az", "cognitiveservices", "account", "keys", "list", "-n", name, "-g", group,
                          "--subscription", sub, "--query", "key2", "-o", "tsv"],
                         capture_output=True, text=True).stdout.strip()
    if not key:
        raise SystemExit("could not read the Azure key: run `az login`")
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


def run(args) -> None:
    path = grid.private_dir(OUT) / "judgments.jsonl"
    done = {r["key"] for r in grid.read_jsonl(path)}
    spent = sum(cost(r["usage"]) for r in grid.read_jsonl(path))
    print(f"already spent ${spent:.2f} over {len(done)} judgments")
    key, budget_start = azure_key(), spent
    with path.open("a") as f:
        for set_name in args.sets:
            clips = outputs(set_name)
            ids = sorted(clips)[: args.limit] if args.limit else sorted(clips)
            for cid in ids:
                outs = clips[cid]
                # identical texts are judged once: the judge sees each distinct cleanup a single time
                distinct = sorted({t for t in outs.values()})
                k = hashlib.sha256(json.dumps([set_name, cid, MODEL, INSTRUCTIONS, outs["raw"], distinct]).encode()).hexdigest()[:20]
                if k in done:
                    continue
                if spent - budget_start >= args.budget:
                    print(f"budget of ${args.budget:.2f} reached; run again to continue")
                    return
                rng = random.Random(k)  # the order is shuffled, but the same on a rerun
                order = rng.sample(distinct, len(distinct))
                labels = [chr(ord("A") + i) for i in range(len(order))]
                grades, usage = ask(key, outs["raw"], list(zip(labels, order)))
                by_text = {t: g for g in grades["versions"] for lab, t in zip(labels, order) if g["label"] == lab}
                best = dict(zip(labels, order)).get(grades["best"])
                row = {"key": k, "set": set_name, "id": cid, "model": MODEL, "usage": usage,
                       "scores": {name: by_text.get(t) for name, t in outs.items()},
                       "best": sorted(n for n, t in outs.items() if t == best)}
                f.write(json.dumps(row) + "\n")
                f.flush()
                spent += cost(usage)
                done.add(k)
    print(f"spent ${spent - budget_start:.2f} this run, ${spent:.2f} in all")


def report(args) -> None:
    rows = grid.read_jsonl(OUT / "judgments.jsonl")
    if not rows:
        raise SystemExit(f"no judgments under {OUT}: run first")
    for set_name in args.sets:
        sel = [r for r in rows if r["set"] == set_name]
        if not sel:
            continue
        # compare only on clips where every output in the table was judged
        names = sorted(set.intersection(*(set(n for n, s in r["scores"].items() if s) for r in sel)))
        print(f"\n{set_name}: {len(sel)} clips judged by {MODEL}, scores 1-5 (mean), and how often each was the pick (identical outputs share a pick, so the column sums past 100%)")
        print("| output | " + " | ".join(CRITERIA) + " | mean | picked |")
        print("|---|" + "--:|" * (len(CRITERIA) + 2))
        for n in sorted(names, key=lambda n: (n != "raw", n)):
            means = [statistics.fmean(r["scores"][n][c] for r in sel) for c in CRITERIA]
            picked = sum(n in r["best"] for r in sel) / len(sel)
            print(f"| {n} | " + " | ".join(f"{m:.2f}" for m in means) + f" | {statistics.fmean(means):.2f} | {100 * picked:.0f}% |")
    print(f"\ncost so far: ${sum(cost(r['usage']) for r in rows):.2f} over {len(rows)} calls")


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
