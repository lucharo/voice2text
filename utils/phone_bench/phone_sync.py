#!/usr/bin/env python3
"""Pull a job's results from the iPhone whenever it is reachable, and print progress and an estimated end.

    ./phone_sync.py jobs/smoke.json              # one sync
    ./phone_sync.py jobs/smoke.json --watch 120  # sync every 2 min until the job ends

Works over USB or Wi-Fi (pair the phone for network use once in Xcode's Devices window). When the phone is
out of reach it reports from the last copy. Results land in --out (default ~/.v2t/eval/phone-jobs/<job>),
and each sync appends one summary row to sync.jsonl there.
"""
import argparse
import json
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

import phone_common as pc

RATE_WINDOW = 30 * 60  # seconds of recent rows the rate is measured over


def clock(t: float) -> str:
    return datetime.fromtimestamp(t).astimezone().strftime("%H:%M %Z")


def ago(s: float) -> str:
    return f"{s:.0f} s" if s < 90 else f"{s / 60:.0f} min" if s < 5400 else f"{s / 3600:.1f} h"


def progress(job: dict, out: Path, now: float, total: int | None = None) -> dict:
    """Summarises the local copies: items done per arm, rate, estimated end, and the phone's last known state."""
    log = pc.read_rows(out / f"{job['name']}.log.jsonl")
    starts = [r for r in log if r.get("event") == "start"]
    if total is None and starts:
        total = starts[-1].get("items")
    if total is None:
        total = pc.item_count(job)
    arms, done_t, last = {}, [], {}
    for a in job["arms"]:
        rows = pc.read_rows(out / f"{job['name']}.{a['id']}.jsonl")
        keys = {r.get("key", r.get("id")): r["t"] for r in rows if r.get("event") in ("clean", "clip")}
        arms[a["id"]] = {"done": len(keys), "errors": sum(bool(r.get("errors")) for r in rows if r.get("event") in ("clean", "clip"))}
        done_t += keys.values()
        for r in rows:
            if r.get("t", 0) >= last.get("t", 0):
                last = r
    for r in log:
        if r.get("t", 0) >= last.get("t", 0):
            last = r
    done = sum(v["done"] for v in arms.values())
    want = total * len(job["arms"]) if total is not None else None
    s = {"job": job["name"], "at": now, "done": done, "total": want, "arms": arms,
         "ended": any(r.get("event") == "end" for r in log[log.index(starts[-1]):]) if starts else False}
    if done_t:
        done_t.sort()
        recent = [t for t in done_t if t >= done_t[-1] - RATE_WINDOW]
        span = recent[-1] - recent[0]
        if len(recent) >= 5 and span >= 60:
            s["per_min"] = round((len(recent) - 1) / span * 60, 2)
            if want and want > done:
                s["eta"] = done_t[-1] + (want - done) / s["per_min"] * 60
    if last:
        s["last_row"] = {k: last.get(k) for k in ("event", "t", "thermal", "battery", "charging", "low_power", "mb", "state") if k in last}
    blocks = [r for r in log if r.get("event") == "block_start"]
    if blocks:
        s["block"] = {k: blocks[-1].get(k) for k in ("arm", "block", "i", "of")}
    states = [r for r in log if r.get("event") == "app"]
    if states:
        s["app_state"] = states[-1].get("state")
    return s


def line(s: dict, link: str | None, now: float) -> str:
    parts = [f"{s['job']}: {s['done']}/{s['total'] or '?'}"]
    parts.append(" ".join(f"{k}={v['done']}" + (f"({v['errors']} err)" if v["errors"] else "") for k, v in s["arms"].items()))
    if s["ended"]:
        parts.append("ENDED")
    elif "eta" in s:
        parts.append(f"{s['per_min']}/min, ends about {clock(s['eta'])}")
    if b := s.get("block"):
        parts.append(f"step {b['i'] + 1}/{b['of']} ({b['arm']} block {b['block'] + 1})")
    if lr := s.get("last_row"):
        th = ["nominal", "fair", "serious", "critical"][lr["thermal"]] if isinstance(lr.get("thermal"), int) else "?"
        bat = f"{lr['battery'] * 100:.0f}%" if isinstance(lr.get("battery"), (int, float)) and lr["battery"] >= 0 else "?"
        parts.append(f"last row {ago(now - lr['t'])} ago, thermal {th}, battery {bat}{' charging' if lr.get('charging') else ''}")
    if s.get("app_state") in ("background", "resign_active", "locked"):
        parts.append(f"app state {s['app_state']}: bring it to the front")
    parts.append(f"phone {'over ' + link if link else 'not reachable, showing the last copy'}")
    if diverged := [k for k, v in s.get("pulled", {}).items() if v == "diverged"]:
        parts.append(f"phone copy diverged from the local one, kept beside it: {', '.join(diverged)}")
    return " | ".join(parts)


def phone_job_name(udid: str) -> str | None:
    """The name in the phone's Documents/job.json: the job a relaunch would resume."""
    with tempfile.TemporaryDirectory() as d:
        if pc.copy_from(udid, "job.json", Path(d) / "job.json") != "copied":
            return None
        try:
            return json.loads((Path(d) / "job.json").read_text()).get("name")
        except ValueError:
            return None


def finished(s: dict) -> bool:
    """The log says the job ended and every arm's results are here in full."""
    return s["ended"] and s["total"] is not None and s["done"] >= s["total"]


def sync_once(job: dict, out: Path, udid: str, relaunch_after: float | None) -> dict:
    link = pc.reach(udid)
    pulled = {}
    if link:
        for name in pc.result_files(job):
            pulled[name] = pc.copy_from(udid, name, out / name)
    now = time.time()
    s = progress(job, out, now)
    s["link"], s["pulled"] = link, pulled
    stale = now - s["last_row"]["t"] if "last_row" in s else None
    # relaunch only on fresh evidence, and only if the phone would resume this job rather than a newer one
    fresh = link and all(v in ("copied", "unchanged") for v in pulled.values())
    if fresh and relaunch_after and not s["ended"] and stale is not None and stale > relaunch_after * 60:
        current = phone_job_name(udid)
        s["relaunched"] = pc.launch(udid) if current == job["name"] else f"no: the phone's job is {current}"
    print(line(s, link, now) + (f" | relaunched: {s['relaunched']}" if "relaunched" in s else ""), flush=True)
    with open(out / "sync.jsonl", "a") as f:
        f.write(json.dumps(s, sort_keys=True) + "\n")
    return s


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("job", type=Path)
    ap.add_argument("--device", help="UDID (default: $V2T_PHONE, else the one paired iPhone)")
    ap.add_argument("--out", type=Path, help="where results go (default ~/.v2t/eval/phone-jobs/<job>)")
    ap.add_argument("--watch", type=float, metavar="SECONDS", help="keep syncing at this interval until the job ends")
    ap.add_argument("--relaunch-after", type=float, metavar="MINUTES",
                    help="relaunch the app (it resumes) when reachable and no row has arrived for this long")
    a = ap.parse_args()
    job = pc.load_job(a.job)
    out = a.out or Path.home() / ".v2t/eval/phone-jobs" / job["name"]
    out.mkdir(parents=True, exist_ok=True)
    (out / "job.json").write_text(a.job.read_text())
    udid = pc.pick_device(a.device)
    while True:
        s = sync_once(job, out, udid, a.relaunch_after)
        if not a.watch or finished(s):
            return 0
        time.sleep(a.watch)


if __name__ == "__main__":
    sys.exit(main())
