"""Replay recordings in real time through VoiceToText.process_live, in a separate
V2T_HOME, with the live transcript on and two preview arms interleaved per clip:
`backend` (Parakeet's own previews) and `nemotron`. Records each partial update with
its time, Nemotron's per-step cost, the wait after release and the pasted text, and
checks the pasted text against one direct `stt.decode(audio)`.

    taskpolicy -b nice -n 19 uv run python utils/nemotron_preview/replay.py OUT.jsonl

The clips are named below from utils/asr_grid's sets (two of them the maintainer's own
dictations, `wispr`); the models must be on disk (nemotron.model_folder()).
Dictation text is never printed: only whether the texts match.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest import mock

EVAL = Path.home() / ".v2t/eval/nemotron-preview"
EVAL.mkdir(parents=True, exist_ok=True)
HOME = Path(tempfile.mkdtemp(prefix="v2t-nemotron-replay-", dir=EVAL))
os.environ["V2T_HOME"] = str(HOME)
sys.path.insert(0, os.getcwd())
import numpy as np  # noqa: E402

from v2t import app, backends, config  # noqa: E402

SETS = Path.home() / ".v2t/eval/grid/sets"


def pick(name, ids):
    rows = {json.loads(line)["id"]: json.loads(line) for line in open(SETS / f"{name}.jsonl")}
    return [{**rows[i], "set": name} for i in ids]


CLIPS = (
    pick("ls-clean", ["1221-135766-0011"])  # 21 s
    + pick("fleurs-es", ["10844880591943993561"])  # 30 s, Spanish, language auto
    + pick("ls-long", ["61-70970-long"])  # 65 s: crosses the 60 s mark
    + [c for c in (json.loads(line) for line in open(SETS / "wispr.jsonl")) if c["id"].startswith(("df419ad6", "0e56a052"))]
)
for c in CLIPS:
    c.setdefault("set", "wispr")


def machine():
    load = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.split()[2]
    free = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout.strip().splitlines()[-1].split()[-1]
    disk = subprocess.run(["df", "-h", "/"], capture_output=True, text=True).stdout.splitlines()[1].split()[3]
    return {"load5": float(load), "mem_free": free, "disk_free": disk}


def replay(voice, audio, block=512):
    updates, last = [], [None]
    real = voice._set_state

    def spy(state, error="", partial=""):
        if state == "recording" and partial and partial != last[0]:
            last[0] = partial
            updates.append((time.perf_counter(), len(partial.split())))
        return real(state, error, partial)

    pasted = {}
    # Never the real paste, not even after this returns: a late worker must not type
    # benchmark text into whatever app has focus.
    voice.paste_to_cursor = lambda t: pasted.setdefault("at", time.perf_counter()) and pasted.setdefault("text", t)
    with mock.patch.object(voice, "_set_state", spy), mock.patch.object(app.sd, "InputStream"):
        voice.start_recording()
        worker = threading.Thread(target=voice.process_next, daemon=True)  # a stuck one must not keep the run alive
        worker.start()
        t0 = time.perf_counter()
        for i in range(0, audio.size, block):
            chunk = audio[i : i + block].reshape(-1, 1)
            voice.audio_callback(chunk, len(chunk), None, None)
            delay = t0 + (i + block) / 16000 - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        released = time.perf_counter()
        voice.stop_recording()
        worker.join(timeout=60)
        if worker.is_alive():
            raise SystemExit("the processing thread did not finish within 60 s of release; stopping")
    stream = voice.preview
    times = [t for t, _ in updates]
    return {
        "updates": len(updates),
        "interval_s": float(np.median(np.diff(times))) if len(times) > 2 else None,
        "first_update_s": times[0] - t0 if times else None,
        "wait_s": pasted.get("at", float("nan")) - released,
        "text": pasted.get("text"),
        "step_ms": [round(s * 1000, 1) for s in stream.step_s] if stream else [],
        "retries": stream.retries if stream else 0,
    }


def main(out_path):
    base = dict(cleanup_enabled=False, live_transcript=True, save_history=False, keep_last_audio=False)
    voices = {
        "backend": app.VoiceToText(config.Config(**base, preview="backend")),
        "nemotron": app.VoiceToText(config.Config(**base, preview="nemotron", preview_language="auto")),
    }
    lock = config.acquire_instance_lock()
    t0 = time.perf_counter()
    stt = backends.make_stt("parakeet-coreml")
    stt.decode(np.zeros(16000, np.float32))
    print(f"parakeet-coreml loaded {time.perf_counter() - t0:.1f}s", flush=True)
    for v in voices.values():
        v.stt = stt
    voices["nemotron"].preview = voices["nemotron"]._load_preview()
    assert voices["nemotron"].preview is not None
    with open(out_path, "w") as out:
        for k, clip in enumerate(CLIPS):
            audio = backends.read_audio(clip["path"], 16000)
            reference = stt.decode(audio)
            arms = list(voices)[k % 2 :] + list(voices)[: k % 2]
            for arm in arms:
                before = machine()
                r = replay(voices[arm], audio)
                row = {"clip": clip["id"], "set": clip["set"], "duration_s": round(audio.size / 16000, 2), "arm": arm,
                       "same_as_decode": r.pop("text") == reference, **r, "before": before, "after": machine()}
                out.write(json.dumps(row) + "\n")
                out.flush()
                steps = sorted(row["step_ms"])
                print(clip["set"], arm, f"{row['duration_s']}s updates={row['updates']} interval={row['interval_s']}"
                      f" wait={row['wait_s']:.3f}s same={row['same_as_decode']}"
                      + (f" step p50={steps[len(steps)//2]} p90={steps[int(len(steps)*0.9)]} retries={row['retries']}" if steps else "")
                      + f" load={before['load5']}", flush=True)
    lock.close()


if __name__ == "__main__":
    main(sys.argv[1])
