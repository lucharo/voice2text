# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Read the v2t keyboard debug log (#162) and report where typing went wrong.

    uv run ios/tools/kb_log_report.py ~/.v2t/eval/kb-logs/<folder>   # a folder from fetch_kb_log.sh
    uv run ios/tools/kb_log_report.py keyboard.jsonl [--json]         # a file, e.g. from the app's Export

Reports:
- autocorrections applied, and how many were taken back (the original picked from the bar, undone as part of
  an address, deleted and typed again, or offered back after a delete and then left);
- likely misses: a word finished, deleted and retyped differently in the same place ("form" -> "from");
- swipes: decoded, typed, kept, replaced from the bar, deleted, and the ones that decoded to nothing;
- suggestion bar taps by slot (left, middle, right), and how many kept the word as typed;
- tap-vs-swipe misreads (#140): swipes made within 350 ms of a tap, or shorter than 300 ms, whose word was
  then deleted or replaced; and fingers typed early by rollover;
- keys per second while typing (bursts with no gap over 2 s).

The log's events are described in ios/README.md ("Keyboard debug log").
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

SLOTS = ["left", "middle", "right"]
FAST_TYPING_MS = 350  # TouchArbiter.fastTypingWindow
SHORT_SWIPE_MS = 300
BURST_GAP_MS = 2000


def read_events(path: Path) -> list[dict]:
    """Every event in the file, or in a folder's keyboard.1.jsonl then keyboard.jsonl, oldest first."""
    files = [path] if path.is_file() else [p for p in (path / "keyboard.1.jsonl", path / "keyboard.jsonl") if p.exists()]
    if not files:
        files = sorted(path.glob("*.jsonl"))
    events = []
    for f in files:
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # a line cut short by the keyboard being killed mid-write
    return events


@dataclass
class Swipe:
    t: float
    word: str | None
    candidates: list
    applied: bool
    ms: float | None = None  # how long the finger was down
    after_tap_ms: float | None = None  # since the last tap lifted
    outcome: str = "kept"  # kept, replaced, deleted, not typed, empty


@dataclass
class Report:
    events: int = 0
    span_s: float = 0
    sessions: int = 0
    skipped_fields: Counter = field(default_factory=Counter)
    corrections: int = 0
    corrections_reverted: Counter = field(default_factory=Counter)
    correction_examples: list = field(default_factory=list)
    reverted_examples: list = field(default_factory=list)
    misses: list = field(default_factory=list)
    swipes: list = field(default_factory=list)
    picks: Counter = field(default_factory=Counter)
    picks_as_typed: int = 0
    picks_emoji: int = 0
    rollovers: int = 0
    multi_finger_downs: int = 0
    taps: int = 0
    kps: list = field(default_factory=list)
    keys: int = 0


class Document:
    """The text before the cursor as the keyboard's own edits and the host's reports leave it, with the words
    finished in it, to find words deleted and retyped differently."""

    def __init__(self) -> None:
        self.text = ""
        self.finished: list[tuple[int, str]] = []  # (start, word) of words followed by a space
        self.deleted: dict[int, str] = {}  # start -> word deleted at that position, waiting to be retyped
        self.misses: list[tuple[str, str]] = []

    def reset(self, before: str) -> None:
        self.text = before
        self.finished = []
        self.deleted = {}

    def insert(self, s: str) -> None:
        for ch in s:
            if ch in " \n\t,.!?;:":
                start = len(self.text)
                while start > 0 and (self.text[start - 1].isalnum() or self.text[start - 1] in "'’"):
                    start -= 1
                word = self.text[start:]
                if word:
                    old = self.deleted.pop(start, None)
                    if old is not None and old.lower() != word.lower():
                        self.misses.append((old, word))
                    self.finished.append((start, word))
            self.text += ch

    def delete(self) -> None:
        if not self.text:
            return
        self.text = self.text[:-1]
        n = len(self.text)
        while self.finished and self.finished[-1][0] + len(self.finished[-1][1]) > n:
            start, word = self.finished.pop()
            if n <= start:  # the whole word went, not just its last letters
                self.deleted[start] = word
            else:
                self.deleted.setdefault(start, word)


def analyse(events: list[dict]) -> Report:
    r = Report(events=len(events))
    if not events:
        return r
    r.span_s = (events[-1]["t"] - events[0]["t"]) / 1000
    doc = Document()
    open_swipe: Swipe | None = None  # the last swipe's word, until it is kept or lost
    pending_offer: dict | None = None
    last_bar: dict | None = None
    last_tap_up: float | None = None
    last_swipe_up: dict | None = None
    key_times: list[float] = []
    corrected: Counter = Counter()  # (replacement, original), lowercase
    reverted_by_keyboard: Counter = Counter()

    def settle_swipe(outcome: str) -> None:
        nonlocal open_swipe
        if open_swipe is not None:
            open_swipe.outcome = outcome
            open_swipe = None

    for ev in events:
        e, t = ev.get("e"), ev.get("t", 0)
        if e == "appear":
            r.sessions += 1
        elif e == "skip":
            r.skipped_fields[ev.get("reason", "?")] += 1
        elif e == "host":
            doc.reset(ev.get("before", ""))
            settle_swipe("kept")
        elif e == "ins":
            # dictation is logged by length only: a placeholder keeps the positions right and forms no word
            doc.insert(ev["text"] if "text" in ev else "█" * ev.get("chars", 0))
            if open_swipe is not None and "text" in ev and ev["text"] != open_swipe.word:
                # a letter or a space after the swiped word: it stays (a pick or delete settles it otherwise)
                if any(c.isalnum() or c.isspace() for c in ev["text"]):
                    settle_swipe("kept")
        elif e == "del":
            doc.delete()
            if open_swipe is not None:
                settle_swipe("deleted")
        elif e == "key":
            r.keys += 1
            key_times.append(t)
        elif e == "down":
            if ev.get("fingers", 0) > 1:  # counts the finger landing too
                r.multi_finger_downs += 1
        elif e == "up":
            if ev.get("verdict") == "tap":
                r.taps += 1
                last_tap_up = t
            elif ev.get("verdict") == "swipe":
                last_swipe_up = {"ms": ev.get("ms"), "after_tap_ms": (t - ev.get("ms", 0) - last_tap_up) if last_tap_up is not None else None}
        elif e == "rollover":
            r.rollovers += 1
            last_tap_up = t
        elif e == "swipe":
            settle_swipe("kept")
            cands = ev.get("candidates", [])
            s = Swipe(t=t, word=cands[0]["w"] if cands else None, candidates=cands, applied=bool(ev.get("applied")))
            if last_swipe_up:
                s.ms, s.after_tap_ms = last_swipe_up["ms"], last_swipe_up["after_tap_ms"]
                last_swipe_up = None
            if not cands:
                s.outcome = "empty"
            elif not s.applied:
                s.outcome = "not typed"
            r.swipes.append(s)
        elif e == "swiped":
            if r.swipes and r.swipes[-1].applied:
                r.swipes[-1].word = ev.get("word")
                open_swipe = r.swipes[-1]
        elif e == "bar":
            last_bar = ev
        elif e == "pick":
            slot = ev.get("slot", 0)
            r.picks[SLOTS[slot] if 0 <= slot < 3 else str(slot)] += 1
            if ev.get("emoji"):
                r.picks_emoji += 1
            kinds = (last_bar or {}).get("kinds", [])
            if 0 <= slot < len(kinds) and kinds[slot] == "typed":
                r.picks_as_typed += 1
        elif e == "picked":
            if open_swipe is not None and ev.get("replaced") == open_swipe.word:
                settle_swipe("replaced")
        elif e == "autocorrect":
            r.corrections += 1
            corrected[(str(ev.get("to")).lower(), str(ev.get("from")).lower())] += 1
            if len(r.correction_examples) < 20:
                r.correction_examples.append(f"{ev.get('from')} -> {ev.get('to')}")
        elif e == "revert-offer":
            pending_offer = ev
        elif e == "revert":
            r.corrections_reverted[ev.get("how", "?")] += 1
            reverted_by_keyboard[(str(ev.get("to")).lower(), str(ev.get("from")).lower())] += 1
            if len(r.reverted_examples) < 20:
                r.reverted_examples.append(f"{ev.get('from')} -> {ev.get('to')} ({ev.get('how')})")
            pending_offer = None
            continue
        if pending_offer is not None and e in ("key", "act", "pick") and not (e == "pick" and ev.get("word") == pending_offer.get("from")):
            # the original was offered back after a delete, and the next thing done was something else
            r.corrections_reverted["offered, left"] += 1
            pending_offer = None
    settle_swipe("kept")
    # a corrected word deleted and the original typed again is a correction taken back, not a miss; the
    # keyboard's own reverts (from the bar, in an address) show up the same way in the text and are counted above
    for old, new in doc.misses:
        pair = (old.lower(), new.lower())
        if reverted_by_keyboard[pair] > 0:
            reverted_by_keyboard[pair] -= 1
        elif corrected[pair] > 0:
            corrected[pair] -= 1
            r.corrections_reverted["retyped"] += 1
        else:
            r.misses.append((old, new))

    # keys per second within bursts
    burst: list[float] = []
    for t in key_times + [float("inf")]:
        if burst and t - burst[-1] > BURST_GAP_MS:
            if len(burst) >= 5:
                r.kps.append((len(burst) - 1) / ((burst[-1] - burst[0]) / 1000))
            burst = []
        burst.append(t)
    return r


def misreads(r: Report) -> list[Swipe]:
    """Swipes whose word was lost and that look like fast taps: right after a tap, or very short."""
    return [s for s in r.swipes if s.outcome in ("deleted", "replaced", "empty")
            and ((s.after_tap_ms is not None and s.after_tap_ms < FAST_TYPING_MS) or (s.ms is not None and s.ms < SHORT_SWIPE_MS))]


def pct(a: int, n: int) -> str:
    return f"{a} of {n} ({100 * a / n:.0f}%)" if n else "0"


def text_report(r: Report) -> str:
    out = [f"{r.events} events over {r.span_s / 60:.1f} min, {r.sessions} keyboard sessions"]
    if r.skipped_fields:
        out.append("fields not recorded: " + ", ".join(f"{k} {v}" for k, v in r.skipped_fields.items()))
    reverted = sum(r.corrections_reverted.values())
    out += ["", "Autocorrect", f"  applied {r.corrections}, taken back {pct(reverted, r.corrections)}"]
    for how, n in r.corrections_reverted.most_common():
        out.append(f"    {how}: {n}")
    out += [f"    {x}" for x in r.reverted_examples[:10]]
    out += ["", "Likely misses (finished, deleted, retyped differently)", f"  {len(r.misses)}"]
    out += [f"    {a} -> {b}" for a, b in r.misses[:20]]
    outcomes = Counter(s.outcome for s in r.swipes)
    out += ["", "Swipes", f"  {len(r.swipes)} decoded: " + ", ".join(f"{k} {v}" for k, v in outcomes.most_common())]
    typed = [s for s in r.swipes if s.applied]
    if typed:
        out.append(f"  kept {pct(outcomes['kept'], len(typed))} of those typed")
    for s in [s for s in r.swipes if s.outcome != "kept"][:10]:
        cands = ", ".join(f"{c['w']} {c['s']:.1f}" for c in s.candidates[:4]) or "nothing"
        out.append(f"    {s.outcome}: {cands}")
    total = sum(r.picks.values())
    out += ["", "Suggestion bar taps", f"  {total}: " + ", ".join(f"{k} {r.picks[k]}" for k in SLOTS if r.picks[k])
            + (f"; as typed {r.picks_as_typed}" if r.picks_as_typed else "") + (f"; emoji {r.picks_emoji}" if r.picks_emoji else "")]
    m = misreads(r)
    out += ["", "Tap vs swipe (#140)",
            f"  taps {r.taps}, typed early by rollover {r.rollovers}, landed with another finger down {r.multi_finger_downs}",
            f"  likely taps read as a swipe: {len(m)}"]
    for s in m[:10]:
        when = f"{s.after_tap_ms:.0f} ms after a tap" if s.after_tap_ms is not None else ""
        out.append(f"    {s.word or 'nothing'} ({s.outcome}; {s.ms or 0:.0f} ms down{', ' + when if when else ''})")
    out += ["", "Speed", f"  {r.keys} keys"]
    if r.kps:
        out.append(f"  keys per second while typing: median {statistics.median(r.kps):.1f}, best {max(r.kps):.1f} ({len(r.kps)} bursts)")
    return "\n".join(out)


def json_report(r: Report) -> dict:
    outcomes = Counter(s.outcome for s in r.swipes)
    return {
        "events": r.events, "span_s": round(r.span_s, 1), "sessions": r.sessions, "skipped_fields": dict(r.skipped_fields),
        "autocorrect": {"applied": r.corrections, "reverted": dict(r.corrections_reverted)},
        "misses": [{"typed": a, "retyped": b} for a, b in r.misses],
        "swipes": {"decoded": len(r.swipes), "outcomes": dict(outcomes)},
        "bar_taps": dict(r.picks), "bar_taps_as_typed": r.picks_as_typed, "bar_taps_emoji": r.picks_emoji,
        "tap_vs_swipe": {"taps": r.taps, "rollovers": r.rollovers, "multi_finger_downs": r.multi_finger_downs,
                         "likely_misreads": len(misreads(r))},
        "keys": r.keys, "kps_median": round(statistics.median(r.kps), 2) if r.kps else None,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", type=Path, help="keyboard.jsonl, an export, or a folder from fetch_kb_log.sh")
    ap.add_argument("--json", action="store_true", help="print the numbers as JSON")
    a = ap.parse_args(argv)
    events = read_events(a.log)
    if not events:
        print(f"no events in {a.log}", file=sys.stderr)
        return 1
    r = analyse(events)
    print(json.dumps(json_report(r), indent=2) if a.json else text_report(r))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
