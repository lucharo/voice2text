"""v2t/nemotron.py against FluidAudio's own Swift (utils/asr_grid's fa-helper, PR #86)
on the same clips: the final text and the sampled partials, token for token.

    swift build -c release --package-path utils/asr_grid/fa_helper   # on PR #86's branch
    FA_HELPER=.../fa-helper uv run python utils/nemotron_preview/parity.py SET.jsonl N

SET.jsonl is one of utils/asr_grid's sets (~/.v2t/eval/grid/sets); each clip uses its
own `lang` as the prompt, as the grid did."""
import json
import os
import subprocess
import sys

sys.path.insert(0, ".")
from v2t import nemotron
from v2t.backends import read_audio

FA = os.environ.get("FA_HELPER", "utils/asr_grid/fa_helper/.build/release/fa-helper")
clips = [json.loads(line) for line in open(sys.argv[1])][: int(sys.argv[2])]
helper = subprocess.Popen([FA, "--nemotron-dir", str(nemotron.FLUIDAUDIO_DIR)], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def ask(req):
    helper.stdin.write(json.dumps(req) + "\n")
    helper.stdin.flush()
    while True:
        line = helper.stdout.readline()
        if line.startswith("@@ "):
            return json.loads(line[3:])
s = nemotron.NemotronStream(language=clips[0]["lang"])
same_final = same_partials = 0
for clip in clips:
    s.prompt[0] = nemotron.LANGUAGES[clip["lang"]]
    fa = ask({"arm": "nemotron", "mode": "stream", "context": "70,7,7", "precision": "fp16", "lang": clip["lang"], "path": clip["path"]})
    audio = read_audio(clip["path"], 16000)
    s.start()
    chunk, first = 7 * 1280, 14 * 1280
    partials, fed, full = [], 0, audio.size // chunk * chunk
    while fed < full:
        s.add(audio[fed:fed + chunk])
        fed += chunk
        s.step()
        if fed >= first:
            partials.append(s.text)
    s.add(audio[fed:])
    s.step(final=True)
    sampled = [p for i, p in enumerate(partials) if i % 4 == 3 or i == len(partials) - 1]
    f_ok = s.text == fa["text"].strip()
    p_ok = sampled == fa["partial_texts"]
    same_final += f_ok
    same_partials += p_ok
    print(clip["id"], f"{clip['duration_s']:.0f}s", "final", "same" if f_ok else "DIFF", "partials", "same" if p_ok else "DIFF",
          f"py step med {sorted(s.step_s)[len(s.step_s)//2]*1e3:.0f} ms / fa {sorted(fa['step_s'])[len(fa['step_s'])//2]*1e3:.0f} ms", flush=True)
    if not f_ok:
        print("  PY", s.text[:300])
        print("  FA", fa["text"][:300])
print(f"final same {same_final}/{len(clips)}, partials same {same_partials}/{len(clips)}")
