#!/usr/bin/env python3
"""Start a batch job on the iPhone: install the app, copy the models the job needs, copy the job file, launch.

    ./phone_push.py jobs/smoke.json

The phone then works through the job by itself; unplug it whenever you like and run phone_sync.py to
collect results. Pushing the same job again resumes it; to start over, give the job a new name.
Models come from --models (default ~/.v2t/eval/phone-models/<model>, a Hugging Face snapshot such as
`hf download mlx-community/Qwen2.5-0.5B-Instruct-4bit --local-dir ~/.v2t/eval/phone-models/mlx-community__Qwen2.5-0.5B-Instruct-4bit`).
"""
import argparse
import json
import sys
import tempfile
from pathlib import Path

import phone_common as pc


def phone_files(udid: str, sub: str) -> set[str] | None:
    """Relative paths of the files under Documents/<sub> in the app, or None if it cannot be listed."""
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        r = pc.devicectl("device", "info", "files", "--device", udid, "--domain-type", "appDataContainer",
                         "--domain-identifier", pc.BUNDLE, "--subdirectory", f"Documents/{sub}",
                         "--json-output", f.name, timeout=300)
        if r.returncode != 0:
            return None
        try:
            files = json.loads(Path(f.name).read_text())["result"]["files"]
        except (ValueError, KeyError):
            return None
    return {x["relativePath"] for x in files if "relativePath" in x}


def model_complete(udid: str, local: Path) -> bool:
    """Every file of the local model folder is on the phone, so an interrupted copy is not mistaken for a done one."""
    have = phone_files(udid, f"models/{local.name}")
    if not have:
        return False
    want = {str(p.relative_to(local)) for p in local.rglob("*") if p.is_file() and p.name != ".DS_Store"}
    return want <= have


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("job", type=Path)
    ap.add_argument("--device", help="UDID (default: $V2T_PHONE, else the one paired iPhone)")
    ap.add_argument("--models", type=Path, default=Path.home() / ".v2t/eval/phone-models")
    ap.add_argument("--app", type=Path, default=pc.APP, help="the built .app (./setup.sh build)")
    ap.add_argument("--no-install", action="store_true", help="keep the app already on the phone")
    ap.add_argument("--recopy-models", action="store_true", help="copy models even if the phone has a folder of that name")
    ap.add_argument("--no-launch", action="store_true")
    a = ap.parse_args()
    job = pc.load_job(a.job)
    models = sorted({arm["model"] for arm in job["arms"] if pc.RUNTIMES[arm["runtime"]]})
    missing = [m for m in models if not (a.models / m).is_dir()]
    if missing:
        sys.exit("not on this Mac: " + ", ".join(str(a.models / m) for m in missing))
    if not a.no_install and not a.app.is_dir():
        sys.exit(f"{a.app} missing: run ./setup.sh build")
    udid = pc.pick_device(a.device)
    link = pc.reach(udid)
    if not link:
        sys.exit(f"phone {udid} is not reachable (USB, or Wi-Fi with network pairing)")
    print(f"phone {udid} over {link}")
    if not a.no_install:
        r = pc.devicectl("device", "install", "app", "--device", udid, str(a.app), timeout=900)
        if r.returncode != 0:
            sys.exit("install failed:\n" + r.stderr[-2000:])
        print("installed", a.app.name)
    for m in models:
        if not a.recopy_models and model_complete(udid, a.models / m):
            print(f"model {m}: already on the phone")
            continue
        print(f"model {m}: copying ...", flush=True)
        if not pc.copy_to(udid, a.models / m, f"Documents/models/{m}"):
            sys.exit(f"copying {m} failed")
    if not pc.copy_to(udid, a.job, "Documents/job.json"):
        sys.exit("copying the job file failed")
    print(f"job {job['name']}: {len(job['arms'])} arms, block {job['block']}, order {job.get('order', 'abba')}")
    if not a.no_launch:
        if not pc.launch(udid):
            sys.exit("launch failed: unlock the phone and run again, or tap the app's icon")
        print("launched; lock it in front with Guided Access, then sync with ./phone_sync.py", a.job)
    return 0


if __name__ == "__main__":
    sys.exit(main())
