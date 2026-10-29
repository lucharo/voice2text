"""Shared helpers for phone_push.py and phone_sync.py: the job file, devicectl, and reading result rows."""
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUNDLE = "es.luischav.v2t.phonebench"
APP = HERE / "build/Build/Products/Release-iphoneos/BenchApp.app"
RUNTIMES = {"mlx": True, "anemll": True, "afm": False, "parakeet-coreml": False, "mlx-stt": True, "bark": False}  # needs a model folder
SETS = {"mlx": "cleanup", "anemll": "cleanup", "afm": "cleanup", "parakeet-coreml": "speech", "mlx-stt": "speech", "bark": "speech"}
ORDERS = ("abba", "alternate", "sequential")


def load_job(path: Path) -> dict:
    """Reads and checks a job file with the same rules the app applies, so a bad job fails on the Mac."""
    job = json.loads(Path(path).read_text())
    errs = []
    for k in ("name", "set", "block", "arms"):
        if k not in job:
            errs.append(f"missing {k!r}")
    if errs:
        raise SystemExit(f"{path}: " + ", ".join(errs))
    if job["set"] not in ("cleanup", "speech"):
        errs.append("set must be cleanup or speech")
    if not isinstance(job["block"], int) or job["block"] < 1:
        errs.append("block must be a positive integer")
    for k, lo in (("offset", 0), ("limit", 0), ("rounds", 1)):
        if k in job and (not isinstance(job[k], int) or job[k] < lo):
            errs.append(f"{k} must be an integer >= {lo}")
    if job.get("order", "abba") not in ORDERS:
        errs.append(f"order must be one of {ORDERS}")
    ids = [a.get("id") for a in job["arms"]]
    if not ids or len(set(ids)) != len(ids) or None in ids:
        errs.append("arms need unique ids")
    if "log" in ids:
        errs.append("arm id log is reserved for the job log")
    if not all(isinstance(x, str) and re.fullmatch(r"[A-Za-z0-9._-]+", x) and x.strip(".") for x in [job["name"], *ids]):
        errs.append("job name and arm ids may use only letters, digits, . _ -")
    for a in job["arms"]:
        rt = a.get("runtime")
        if rt not in RUNTIMES:
            errs.append(f"arm {a.get('id')}: unknown runtime {rt!r}")
        elif SETS[rt] != job["set"]:
            errs.append(f"arm {a['id']}: runtime {rt} runs on the {SETS[rt]} set, not {job['set']}")
        elif RUNTIMES[rt] and not a.get("model"):
            errs.append(f"arm {a['id']}: runtime {rt} needs a model")
    if errs:
        raise SystemExit(f"{path}: " + "; ".join(errs))
    return job


def result_files(job: dict) -> list[str]:
    """Documents file names the app writes for this job: the log, then one per arm."""
    return [f"{job['name']}.log.jsonl"] + [f"{job['name']}.{a['id']}.jsonl" for a in job["arms"]]


def item_count(job: dict, res: Path = HERE / "Res") -> int | None:
    """Items per arm (all rounds), counted from the staged resources; None if they are not staged here."""
    f = res / ("cleanup/inputs.jsonl" if job["set"] == "cleanup" else "clips/manifest.tsv")
    if not f.exists():
        return None
    with f.open() as fh:
        n = sum(1 for line in fh if line.strip())
    lo = min(job.get("offset", 0), n)
    return (min(lo + job.get("limit", n), n) - lo) * max(job.get("rounds", 1), 1)


def read_rows(path: Path) -> list[dict]:
    """JSONL rows; a line cut short mid-write (even mid-character) is skipped."""
    rows = []
    try:
        with path.open("rb") as f:
            for line in f:
                try:
                    rows.append(json.loads(line.decode("utf-8")))
                except ValueError:  # UnicodeDecodeError is a ValueError too
                    pass
    except OSError:
        pass
    return rows


def devicectl(*args: str, timeout: float = 120) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["xcrun", "devicectl", *args], check=False, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(e.cmd, 124, "", f"timed out after {timeout:.0f} s")


def devices() -> list[dict]:
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        devicectl("list", "devices", "--json-output", f.name, timeout=60)
        try:
            return json.loads(Path(f.name).read_text())["result"]["devices"]
        except (ValueError, KeyError):
            return []


def pick_device(udid: str | None) -> str:
    """--device, else $V2T_PHONE, else the one paired iPhone that is not this Mac's iPhone Mirroring entry."""
    udid = udid or os.environ.get("V2T_PHONE")
    if udid:
        return udid
    phones = [d for d in devices() if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
              and d.get("connectionProperties", {}).get("transportType") != "sameMachine"
              and d.get("connectionProperties", {}).get("pairingState") == "paired"]
    if len(phones) != 1:
        names = ", ".join(f"{d['deviceProperties'].get('name')} ({d['hardwareProperties'].get('udid')})" for d in phones) or "none"
        raise SystemExit(f"pass --device or set V2T_PHONE; paired iPhones: {names}")
    return phones[0]["hardwareProperties"]["udid"]


def reach(udid: str) -> str | None:
    """How the phone answers now ("wired" for USB, "localNetwork" for Wi-Fi), or None when it doesn't.
    Asking for device details makes CoreDevice open a tunnel over whichever link works."""
    if devicectl("device", "info", "details", "--device", udid, timeout=45).returncode != 0:
        return None
    for d in devices():
        if d.get("hardwareProperties", {}).get("udid") == udid or d.get("identifier") == udid:
            return d.get("connectionProperties", {}).get("transportType", "unknown")
    return "unknown"


def copy_from(udid: str, name: str, dest: Path) -> str:
    """Copies Documents/<name> from the app to dest, replacing the local copy only when the local bytes are
    a prefix of the phone's, so synced results only grow. A phone copy that diverges (the app was reinstalled,
    or the job restarted under the same name) is kept beside it as <name>.diverged-<time>.jsonl and reported."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    r = devicectl("device", "copy", "from", "--device", udid, "--domain-type", "appDataContainer",
                  "--domain-identifier", BUNDLE, "--source", f"Documents/{name}", "--destination", str(tmp), timeout=300)
    if r.returncode != 0 or not tmp.exists():
        tmp.unlink(missing_ok=True)
        return "absent"
    if dest.exists():
        have, new = dest.read_bytes(), tmp.read_bytes()
        if new == have:
            tmp.unlink()
            return "unchanged"
        if not new.startswith(have):
            tmp.replace(dest.with_name(f"{dest.stem}.diverged-{time.strftime('%Y%m%d-%H%M%S')}{dest.suffix}"))
            return "diverged"
    tmp.replace(dest)
    return "copied"


def copy_to(udid: str, src: Path, dest: str) -> bool:
    r = devicectl("device", "copy", "to", "--device", udid, "--domain-type", "appDataContainer",
                  "--domain-identifier", BUNDLE, "--source", str(src), "--destination", dest, timeout=1800)
    return r.returncode == 0


def launch(udid: str) -> bool:
    """(Re)launches the app with no arguments, so it reads Documents/job.json and resumes."""
    return devicectl("device", "process", "launch", "--device", udid, "--terminate-existing", BUNDLE, timeout=90).returncode == 0
