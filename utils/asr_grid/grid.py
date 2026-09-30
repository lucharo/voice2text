"""ASR model grid: which speech-to-text model should v2t run, and should it stream?

Maintainer-only, not packaged. One cell = one system on one clip set, run in the
environment that has that system's runtime; cells resume where they stopped.

    python grid.py prepare                                   # build the clip-set manifests
    python grid.py run --system parakeet-v3 --set wispr      # one cell
    python grid.py report                                    # every finished cell, one table

Sets: `wispr` (your own dictations, from the Wispr Flow bench export; no labels),
`ls-clean` / `ls-other` (LibriSpeech test, labelled, English) and `fleurs-es`
(FLEURS es_419 test, labelled, Spanish), 150 clips each, seeded. Labelled sets get a
real WER. The `wispr` set has no ground truth (Wispr's own text is not truth), so each
system is scored against the leave-one-out medoid of every other system's transcript
plus Wispr's ASR: the transcript the rest agree with most.

Latency is the wait after the hotkey is released: the whole-file decode for an offline
system; for a streaming one, the final push plus flush after everything before it was
fed and drained. Streaming cells also report the real-time factor (compute / audio),
which must stay under 1 to keep up live.

Everything written goes under ~/.v2t/eval/grid (owner-only): manifests, per-clip
results with transcripts, and the report, which carries numbers only. Models load
offline from the Hugging Face cache (HF_HUB_OFFLINE=1); nothing is downloaded here.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import time
from datetime import date
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_OFFLINE", "1")

REPO = Path(__file__).resolve().parents[2]
EVAL = Path.home() / ".v2t/eval"
GRID = EVAL / "grid"
SETS = GRID / "sets"
RESULTS = GRID / "results"
LIBRISPEECH = EVAL / "labelled/LibriSpeech"
FLEURS_ES = EVAL / "labelled/fleurs/es_419"
WISPR = EVAL / "wisprflow"
SAMPLE = 150
SEED = 20260929
SAMPLE_RATE = 16000
STREAM_FEED_S = 0.5  # audio handed to a streaming session between drains

# name -> runtime, repository, mode. `offline` decodes the whole clip after
# release; `hacky` is v2t as shipped (Parakeet's local-attention stream, 5 s
# pushes, streamed text taken from 60 s up); `stream` is a natively streaming
# session fed as the audio arrives.
SYSTEMS = {
    "parakeet-v3": ("parakeet-mlx", "mlx-community/parakeet-tdt-0.6b-v3", "hacky"),
    "parakeet-ultra": ("parakeet-mlx", "selcukkubur/parakeet-ultra-mlx", "hacky"),
    "whisper-turbo": ("mlx-whisper", "mlx-community/whisper-large-v3-turbo", "offline"),
    "nemotron-3.5-stream": (
        "mlx-audio",
        "mlx-community/nemotron-3.5-asr-streaming-0.6b",
        "stream",
    ),
    "voxtral-rt-4bit": (
        "mlx-audio",
        "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
        "stream",
    ),
    "qwen3-asr-1.7b": ("mlx-audio", "mlx-community/Qwen3-ASR-1.7B-bf16", "offline"),
    "qwen3-asr-1.7b-8bit": (
        "mlx-audio",
        "mlx-community/Qwen3-ASR-1.7B-8bit",
        "offline",
    ),
    # the same weights as parakeet-v3 and whisper-turbo, through mlx-audio's own
    # implementations: could one package replace parakeet-mlx and mlx-whisper?
    "parakeet-v3-mlxaudio": (
        "mlx-audio",
        "mlx-community/parakeet-tdt-0.6b-v3",
        "offline",
    ),
    "whisper-turbo-mlxaudio": (
        "mlx-audio",
        "mlx-community/whisper-large-v3-turbo",
        "offline",
    ),
}


# --- text -------------------------------------------------------------------

_WORD = re.compile(r"[\w']+")


def normalise(text: str | None, lang: str) -> list[str]:
    """Open ASR Leaderboard normalisation (Whisper's), then words."""
    from whisper_normalizer.basic import BasicTextNormalizer
    from whisper_normalizer.english import EnglishTextNormalizer

    norm = EnglishTextNormalizer() if lang == "en" else BasicTextNormalizer()
    return _WORD.findall(norm(text or "").lower())


def edits(ref: list[str], hyp: list[str]) -> int:
    """Word-level Levenshtein distance (symmetric)."""
    from rapidfuzz.distance import Levenshtein

    return Levenshtein.distance(ref, hyp)


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


# --- clip sets ----------------------------------------------------------------


def prepare() -> None:
    private_dir(SETS)
    sets = {"wispr": wispr_set()}
    if LIBRISPEECH.exists():
        sets["ls-clean"] = librispeech_set("test-clean")
        sets["ls-other"] = librispeech_set("test-other")
    if FLEURS_ES.exists():
        sets["fleurs-es"] = fleurs_set()
    for name, clips in sets.items():
        path = SETS / f"{name}.jsonl"
        path.write_text("".join(json.dumps(c) + "\n" for c in clips))
        path.chmod(0o600)
        hours = sum(c["duration_s"] for c in clips) / 3600
        print(f"{name}: {len(clips)} clips, {hours:.2f} h -> {path}")


def _duration(path: Path) -> float:
    import soundfile as sf

    return sf.info(str(path)).duration


def wispr_set() -> list[dict]:
    """Every exported Wispr clip, with Wispr's own ASR kept as one consensus voter."""
    meta = {c["id"]: c for c in read_jsonl(WISPR / "results.jsonl")}
    clips = []
    for wav in sorted((WISPR / "audio").glob("*.wav")):
        clips.append(
            {
                "id": wav.stem,
                "path": str(wav),
                "duration_s": round(_duration(wav), 3),
                "lang": "en",
                "text": None,
                "wispr_asr": meta.get(wav.stem, {}).get("wispr_asr"),
            }
        )
    return clips


def librispeech_set(split: str) -> list[dict]:
    rows = []
    for trans in sorted((LIBRISPEECH / split).rglob("*.trans.txt")):
        for line in trans.read_text().splitlines():
            utt, text = line.split(" ", 1)
            rows.append((utt, trans.parent / f"{utt}.flac", text))
    random.Random(SEED).shuffle(rows)
    return [
        {
            "id": utt,
            "path": str(path),
            "duration_s": round(_duration(path), 3),
            "lang": "en",
            "text": text,
        }
        for utt, path, text in sorted(rows[:SAMPLE])
    ]


def fleurs_set() -> list[dict]:
    rows = []
    for line in (FLEURS_ES / "test.tsv").read_text().splitlines():
        fields = line.split("\t")
        wav = FLEURS_ES / "audio/test" / fields[1]
        if wav.exists():
            rows.append((fields[1], wav, fields[2]))  # raw transcription
    random.Random(SEED).shuffle(rows)
    return [
        {
            "id": name.removesuffix(".wav"),
            "path": str(path),
            "duration_s": round(_duration(path), 3),
            "lang": "es",
            "text": text,
        }
        for name, path, text in sorted(rows[:SAMPLE])
    ]


def load_audio(path: str) -> np.ndarray:
    """Mono float32 at 16 kHz (every set is 16 kHz already)."""
    import soundfile as sf

    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    if rate != SAMPLE_RATE:
        raise SystemExit(f"{path}: {rate} Hz, expected {SAMPLE_RATE}")
    return audio.mean(axis=1)


# --- runtimes -----------------------------------------------------------------


class ParakeetMLX:
    """v2t's own Parakeet backend: whole-file decode plus, for `hacky`, the
    shipped streaming path (5 s pushes through ChunkFeeder, finish on release)."""

    def __init__(self, repo: str, mode: str):
        sys.path.insert(0, str(REPO))
        from v2t import backends

        self.backends = backends
        self.stt = backends.ParakeetSTT(repo)
        self.mode = mode

    def run(self, clip: dict) -> dict:
        t0 = time.perf_counter()
        text = self.stt.transcribe(clip["path"])
        out = {"offline": text, "offline_s": time.perf_counter() - t0}
        if self.mode == "hacky":
            out.update(self._stream(load_audio(clip["path"])))
        return out

    def _stream(self, audio: np.ndarray) -> dict:
        stream = self.stt.stream()
        busy = [0.0]

        def sink(chunk: np.ndarray) -> None:
            t0 = time.perf_counter()
            stream.feed(chunk)
            busy[0] += time.perf_counter() - t0

        feeder = self.backends.ChunkFeeder(sink, SAMPLE_RATE)
        try:
            step = feeder.chunk_samples
            for start in range(0, len(audio), step):
                feeder.push(audio[start : start + step])
            t_release = time.perf_counter()
            text = stream.finish(feeder.take())
            stream = None
            wait = time.perf_counter() - t_release
        finally:
            if stream is not None:
                stream.close()
        return {"stream": text, "stream_wait_s": wait, "stream_busy_s": busy[0] + wait}


class MLXWhisper:
    def __init__(self, repo: str, mode: str):
        sys.path.insert(0, str(REPO))
        from v2t import backends

        self.stt = backends.WhisperSTT(repo)

    def run(self, clip: dict) -> dict:
        t0 = time.perf_counter()
        text = self.stt.transcribe(clip["path"])
        return {"offline": text, "offline_s": time.perf_counter() - t0}


class MLXAudio:
    """mlx-audio 0.5.7: `generate` for offline models, a streaming session
    (feed / step / close) for natively streaming ones."""

    def __init__(self, repo: str, mode: str):
        from mlx_audio.stt import load

        self.model = load(repo)
        self.mode = mode

    def run(self, clip: dict) -> dict:
        audio = load_audio(clip["path"])
        if self.mode == "offline":
            if "parakeet" in type(self.model).__name__.lower():
                import mlx.core as mx

                audio = mx.array(audio)  # its generate takes a path or an mx.array
            t0 = time.perf_counter()
            result = self.model.generate(audio)
            return {
                "offline": result.text.strip(),
                "offline_s": time.perf_counter() - t0,
            }
        return self._stream(audio)

    def _session(self, audio_s: float):
        kind = type(self.model).__name__.lower()
        if "voxtral" in kind:
            # one decoder position per 80 ms, plus the delay and right pad
            return self.model.create_streaming_session(
                max_tokens=int(audio_s / 0.08) + 512
            )
        return self.model.create_streaming_session()

    @staticmethod
    def _pending(session) -> bool:
        """Work already fed but not yet decoded (pinned to mlx-audio 0.5.7 internals)."""
        if hasattr(session, "_audio_q"):  # Voxtral
            if session._audio_q:
                return True
            if not session._prefilled:
                return session._n_adapter() >= session._prompt_len
            return session._n_adapter() > session._pos
        return bool(session._audio) or bool(session._encoded)  # Nemotron

    def _drain(self, session, parts: list[str]) -> None:
        parts.extend(session.step(max_decode_tokens=64))
        while not session.done and self._pending(session):
            parts.extend(session.step(max_decode_tokens=64))

    def _stream(self, audio: np.ndarray) -> dict:
        session = self._session(len(audio) / SAMPLE_RATE)
        feed = int(SAMPLE_RATE * STREAM_FEED_S)
        parts: list[str] = []
        busy = 0.0
        last = max(0, (len(audio) - 1) // feed * feed)  # the push that follows release
        for start in range(0, last, feed):
            t0 = time.perf_counter()
            session.feed(audio[start : start + feed])
            self._drain(session, parts)
            busy += time.perf_counter() - t0
        t_release = time.perf_counter()
        session.feed(audio[last:])
        session.close()
        while not session.done:
            parts.extend(session.step(max_decode_tokens=64))
        wait = time.perf_counter() - t_release
        return {
            "stream": "".join(parts).strip(),
            "stream_wait_s": wait,
            "stream_busy_s": busy + wait,
        }


RUNTIMES = {
    "parakeet-mlx": ParakeetMLX,
    "mlx-whisper": MLXWhisper,
    "mlx-audio": MLXAudio,
}


def run(system: str, set_name: str, limit: int | None) -> None:
    runtime, repo, mode = SYSTEMS[system]
    clips = read_jsonl(SETS / f"{set_name}.jsonl")
    if not clips:
        raise SystemExit(f"no clips for {set_name}; run `prepare` first")
    out_path = private_dir(RESULTS / set_name) / f"{system}.jsonl"
    done = {r["id"] for r in read_jsonl(out_path)}
    todo = [c for c in clips if c["id"] not in done][:limit]
    print(
        f"{system} on {set_name}: {len(done)} done, {len(todo)} to go ({repo}, {mode})"
    )
    if not todo:
        return
    t0 = time.perf_counter()
    engine = RUNTIMES[runtime](repo, mode)
    print(f"loaded in {time.perf_counter() - t0:.1f}s")
    warm = min(clips, key=lambda c: c["duration_s"])
    engine.run(warm)  # warm-up on the shortest clip: the first decode compiles kernels
    with out_path.open("a") as out:
        os.chmod(out_path, 0o600)
        for n, clip in enumerate(todo, 1):
            result = {
                "id": clip["id"],
                "duration_s": clip["duration_s"],
                **engine.run(clip),
            }
            out.write(json.dumps(result) + "\n")
            out.flush()
            if n % 10 == 0 or n == len(todo):
                print(f"  {n}/{len(todo)}", flush=True)


# --- report -------------------------------------------------------------------


def final_text(system: str, row: dict) -> str:
    """The text a user would get: v2t's hacky rule, the stream, or the whole file."""
    mode = SYSTEMS[system][2]
    if mode == "hacky":
        return row["stream"] if row["duration_s"] >= 60 else row["offline"]
    return row["stream"] if mode == "stream" else row["offline"]


def wait_s(system: str, row: dict) -> float:
    mode = SYSTEMS[system][2]
    if mode == "hacky":
        return row["stream_wait_s"] if row["duration_s"] >= 60 else row["offline_s"]
    return row["stream_wait_s"] if mode == "stream" else row["offline_s"]


def q(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))]


def score_set(set_name: str) -> list[dict]:
    """One row per system on the clips every system finished, so rows compare.

    Rows carry the pooled error and reference-word counts, the per-clip waits and
    the compute and audio totals, so sets can be pooled downstream.
    """
    clips = {c["id"]: c for c in read_jsonl(SETS / f"{set_name}.jsonl")}
    cells = {
        p.stem: {r["id"]: r for r in read_jsonl(p)}
        for p in sorted((RESULTS / set_name).glob("*.jsonl"))
        if p.stem in SYSTEMS
    }
    if not cells:
        return []
    common = sorted(set(clips).intersection(*[set(rows) for rows in cells.values()]))
    errors = dict.fromkeys(cells, 0)
    words = dict.fromkeys(cells, 0)
    for cid in common:
        clip = clips[cid]
        hyps = {s: normalise(final_text(s, cells[s][cid]), clip["lang"]) for s in cells}
        if clip["text"] is not None:
            ref = normalise(clip["text"], clip["lang"])
            for s in cells:
                errors[s] += edits(ref, hyps[s])
                words[s] += len(ref)
            continue
        # no label: the leave-one-out medoid of the other systems plus Wispr's ASR
        voters = dict(hyps)
        if clip.get("wispr_asr"):
            voters["wispr-asr"] = normalise(clip["wispr_asr"], clip["lang"])
        names = list(voters)
        pair = {
            frozenset((a, b)): edits(voters[a], voters[b])
            for i, a in enumerate(names)
            for b in names[i + 1 :]
        }

        def dist(a: str, b: str) -> int:
            return 0 if a == b else pair[frozenset((a, b))]

        for s in cells:
            others = [n for n in names if n != s]
            if not others:  # a lone system and no Wispr ASR: nothing to agree with
                continue
            ref_name = min(others, key=lambda c: sum(dist(c, o) for o in others))
            errors[s] += dist(ref_name, s)
            words[s] += len(voters[ref_name])
    rows = []
    for system, rows_by_id in cells.items():
        waits = [wait_s(system, rows_by_id[cid]) for cid in common]
        busy = sum(
            rows_by_id[cid].get("stream_busy_s") or rows_by_id[cid]["offline_s"]
            for cid in common
        )
        audio = sum(clips[cid]["duration_s"] for cid in common)
        rows.append(
            {
                "system": system,
                "mode": SYSTEMS[system][2],
                "n": len(common),
                "errors": errors[system],
                "words": words[system],
                "wer": errors[system] / words[system]
                if words[system]
                else float("nan"),
                "waits": waits,
                "wait_p50": q(waits, 0.5) if waits else float("nan"),
                "wait_p90": q(waits, 0.9) if waits else float("nan"),
                "wait_max": max(waits) if waits else float("nan"),
                "busy_s": busy,
                "audio_s": audio,
                "rtf": busy / audio if audio else float("nan"),
            }
        )
    return sorted(rows, key=lambda r: r["wer"])


def report() -> None:
    lines = [f"# ASR grid, {date.today().isoformat()}", ""]
    lines.append(
        "WER: labelled sets against their references; `wispr` against the leave-one-out "
        "consensus of the other systems plus Wispr's ASR (agreement, not truth). Wait: "
        "seconds from release to final text. RTF: compute / audio."
    )
    for set_path in sorted(SETS.glob("*.jsonl")):
        rows = score_set(set_path.stem)
        if not rows:
            continue
        lines += [
            "",
            f"## {set_path.stem} ({rows[0]['n']} clips)",
            "",
            "| system | mode | WER | wait p50 | p90 | max | RTF |",
            "|---|---|--:|--:|--:|--:|--:|",
        ]
        for r in rows:
            lines.append(
                f"| {r['system']} | {r['mode']} | {r['wer']:.1%} | {r['wait_p50']:.2f}s "
                f"| {r['wait_p90']:.2f}s | {r['wait_max']:.2f}s | {r['rtf']:.3f} |"
            )
    path = GRID / f"{date.today().isoformat()}-report.md"
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)
    print("\n".join(lines))
    print(f"\n-> {path}")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare")
    r = sub.add_parser("run")
    r.add_argument("--system", choices=sorted(SYSTEMS), required=True)
    r.add_argument("--set", dest="set_name", required=True)
    r.add_argument("--limit", type=int)
    sub.add_parser("report")
    a = p.parse_args(argv)
    private_dir(GRID)
    if a.command == "prepare":
        prepare()
    elif a.command == "run":
        run(a.system, a.set_name, a.limit)
    else:
        report()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
