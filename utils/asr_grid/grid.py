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
system is scored against the leave-one-out medoid of every other system's transcript:
the transcript the rest agree with most. Wispr votes through its API run
(`wispr-flow-api`), never through the text its app stored.

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
NOISY = ("ami-sdm", "earnings22")  # fetched by fetch_noisy.py into EVAL/labelled/<set>
WISPR = EVAL / "wisprflow"
SAMPLE = 150
SEED = 20260929
SAMPLE_RATE = 16000
STREAM_FEED_S = 0.5  # audio handed to a streaming session between drains
TAKEOVER_S = 60  # v2t keeps the streamed text from here up (backends.STREAM_TAKEOVER_S)
CHUNK_S = 30  # the `chunked` pass: decode each ~30 s piece while recording
CHUNK_SEARCH_S = 5  # cut at the quietest 100 ms within this many seconds of the mark
# Whole-file Parakeet attention grows with the square of the length: measured
# 2026-10-14, 6.8 GB at 336 s and over 18 GB (31 GB unchecked, which took the Mac
# down) at 738 s. Clips longer than this (eight `wispr` dictations, ls-long's
# longest) go through the runtime's own long-file chunking, in pieces this long,
# for the systems added from 2026-10-14; the earlier rows decoded them whole.
WHOLE_FILE_MAX_S = 300

# name -> runtime, repository, mode. `offline` decodes the whole clip after
# release; `hacky` is v2t as shipped (Parakeet's local-attention stream, 5 s
# pushes, streamed text taken from 60 s up); `stream` is a natively streaming
# session fed as the audio arrives.
SYSTEMS = {
    "parakeet-v3": ("parakeet-mlx", "mlx-community/parakeet-tdt-0.6b-v3", "hacky"),
    "parakeet-ultra": ("parakeet-mlx", "selcukkubur/parakeet-ultra-mlx", "hacky"),
    # v2t's opt-in parakeet-coreml decode: FluidAudio's Parakeet v3 Core ML files on
    # the Neural Engine (v2t/coreml.py), whole-file; the repo is where they come from
    "parakeet-v3-coreml": (
        "parakeet-coreml",
        "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        "offline",
    ),
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
    # Cohere Transcribe 03-2026 (2B, Apache-2.0), told the clip's language. mlx-audio
    # reads the original Transformers checkpoint; CohereLabs gates it behind a login,
    # so this is an ungated mirror (same weights hash as a second mirror, same
    # config and tokenizer as the original). The MLX conversions on the Hub
    # (beshkenadze/*, mlx-community/*) use mlx-audio-swift or mlx-speech tensor
    # names, which mlx-audio's Python loader silently leaves unloaded.
    "cohere-transcribe": (
        "mlx-audio",
        "viethang/cohere-transcribe-03-2026",
        "offline",
    ),
    # ...decoding only the speech: Cohere loops on silence ("the world is a world of
    # peace" for 13k characters, 2026-10-24 read-through), so this cuts each clip into
    # speech segments first (speech_segments) and joins their texts
    "cohere-transcribe-vad": (
        "mlx-audio",
        "viethang/cohere-transcribe-03-2026#vad",
        "offline",
    ),
    # Moondream's ternary (1.58-bit) Parakeet v3, 178 MB
    "parakeet-redux": ("mlx-audio", "moondream/parakeet-redux", "offline"),
    # NVIDIA's English Parakeet Unified, offline (full-context) mode only, from the
    # fp32 MLX conversion cast to bf16 like every other parakeet-mlx row
    "parakeet-unified-en": (
        "parakeet-mlx",
        "littlebearlabs/parakeet-unified-en-0.6b-mlx",
        "offline",
    ),
    # Fermion's Parakeet v3 retrained at ~2.1 bits (164 MB), English only, through
    # its own MLX runtime (fermion-research, on mlx-audio's Parakeet graph) at its
    # defaults, which dequantise the encoder to fp16 after load...
    "phonon-2": ("fermion", "FermionResearch/Phonon-2", "offline"),
    # ...and with the encoder kept packed (FERMION_P2_FAST=tdt16, its bit-exact
    # path): the memory a phone would need
    "phonon-2-packed": ("fermion", "FermionResearch/Phonon-2#tdt16", "offline"),
    # Wispr Flow's cloud service through the desktop app's own gRPC route, run by
    # .ignored_scripts/wispr_api.py, local only (not `run`): one request per clip after release
    "wispr-flow-api": ("wispr-cloud", "flow_api.v1.TranscriptionService/Transcribe", "offline"),
}
ENGLISH_ONLY = {"parakeet-unified-en", "phonon-2", "phonon-2-packed"}  # no fleurs-es


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
        sets["ls-long"] = librispeech_long_set()
    if FLEURS_ES.exists():
        sets["fleurs-es"] = fleurs_set()
    for name in NOISY:
        if (EVAL / "labelled" / name / "transcripts.tsv").exists():
            sets[name] = noisy_set(name)
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
    """Every exported Wispr clip, with the text Wispr's app stored for it (`wispr_asr`).

    That text is Wispr's final output, often already formatted and on fallback
    dictations cut to the last sentence (2026-10-24 read-through), so it is scored by
    `score_wispr_flow` but never votes in the consensus.
    """
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


def librispeech_long_set() -> list[dict]:
    """Labelled long clips: consecutive utterances of one chapter joined into one file.

    Every other labelled clip is under 60 s, so v2t's 60 s rule never fires on them.
    These, 60 to 300 s like the long dictations, put the stream and the chunk pass
    against a real reference. 20 chapters from each test split, seeded.
    """
    import soundfile as sf

    out_dir = private_dir(SETS / "ls-long")
    rng = random.Random(SEED)
    clips = []
    for split in ("test-clean", "test-other"):
        chapters = sorted(p for p in (LIBRISPEECH / split).glob("*/*") if p.is_dir())
        for chapter in sorted(rng.sample(chapters, 20)):
            target = rng.uniform(60, 300)
            trans = next(chapter.glob("*.trans.txt"))
            audio, texts = [], []
            for line in trans.read_text().splitlines():
                utt, text = line.split(" ", 1)
                audio.append(sf.read(str(chapter / f"{utt}.flac"), dtype="float32")[0])
                texts.append(text)
                if sum(len(a) for a in audio) >= target * SAMPLE_RATE:
                    break
            joined = np.concatenate(audio)
            if len(joined) < 60 * SAMPLE_RATE:
                continue  # a chapter too short to reach the rule
            clip_id = f"{chapter.parent.name}-{chapter.name}-long"
            path = out_dir / f"{clip_id}.wav"
            sf.write(str(path), joined, SAMPLE_RATE, subtype="PCM_16")
            clips.append(
                {
                    "id": clip_id,
                    "path": str(path),
                    "duration_s": round(len(joined) / SAMPLE_RATE, 3),
                    "lang": "en",
                    "text": " ".join(texts),
                }
            )
    return clips


def noisy_set(name: str) -> list[dict]:
    """A set fetch_noisy.py already sampled: its WAVs and their reference texts."""
    root = EVAL / "labelled" / name
    clips = []
    for line in (root / "transcripts.tsv").read_text().splitlines():
        cid, text = line.split("\t", 1)
        path = root / "audio" / f"{cid}.wav"
        clips.append(
            {"id": cid, "path": str(path), "duration_s": round(_duration(path), 3), "lang": "en", "text": text}
        )
    return clips


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


def release_cache() -> None:
    """Return MLX's buffer cache between clips, outside any timing.

    MLX keeps freed buffers for reuse, and a long clip's buffers rarely fit the next
    one: the cache grew about 3.5 GB per ls-long clip, so a 40-clip pass swapped a
    48 GB Mac and inflated the waits (2026-10-06).
    """
    import mlx.core as mx

    mx.clear_cache()


def measured(work) -> dict:
    """`work()`'s result plus MLX's peak memory while it ran (weights included,
    since they stay resident), in GB."""
    import mlx.core as mx

    mx.reset_peak_memory()
    result = work()
    return {**result, "peak_mem_gb": round(mx.get_peak_memory() / 1e9, 3)}


# --- runtimes -----------------------------------------------------------------


class ParakeetMLX:
    """v2t's own Parakeet backend: whole-file decode plus, for `hacky`, the
    shipped streaming path (5 s pushes through ChunkFeeder, finish on release)."""

    def __init__(self, repo: str, mode: str):
        sys.path.insert(0, str(REPO))
        from v2t import backends

        self.backends = backends
        # v2t quantizes Parakeet to PARAKEET_BITS at load since 0.5.15; the grid's
        # parakeet-mlx rows are bf16, so this process keeps full precision
        backends._quantized = lambda model: model
        if (Path(_snapshot(repo)) / "config.json").exists():
            self.stt = backends.ParakeetSTT(repo)  # bf16, as parakeet-mlx loads it
        else:
            self.stt = backends.ParakeetSTT.__new__(backends.ParakeetSTT)
            self.stt.model = load_nemo_layout(_snapshot(repo))
        self.mode = mode

    def run(self, clip: dict) -> dict:
        t0 = time.perf_counter()
        if self.mode == "hacky" or clip["duration_s"] <= WHOLE_FILE_MAX_S:
            text = self.stt.transcribe(clip["path"])
        else:  # parakeet-mlx's own chunking (15 s overlap, its default)
            text = self.stt.model.transcribe(
                clip["path"], chunk_duration=WHOLE_FILE_MAX_S
            ).text.strip()
        out = {"offline": text, "offline_s": time.perf_counter() - t0}
        if self.mode == "hacky":
            out.update(self._stream(load_audio(clip["path"])))
        return out

    def decode(self, audio: np.ndarray) -> str:
        """What `transcribe` does after reading the file (parakeet-mlx 0.5)."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        model = self.stt.model
        mel = get_logmel(mx.array(audio), model.preprocessor_config)  # float32, as load_audio
        return model.generate(mel)[0].text.strip()

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
        return {"stream": text, "stream_wait_s": wait,
                "stream_feed_s": busy[0], "stream_busy_s": busy[0] + wait}


def _snapshot(repo: str) -> str:
    from huggingface_hub import snapshot_download

    return snapshot_download(repo)  # offline: the cached snapshot's path


def load_nemo_layout(folder: str):
    """v2t's own loader for NeMo-layout Parakeet checkpoints (backends.load_nemo_layout)."""
    sys.path.insert(0, str(REPO))
    from v2t.backends import load_nemo_layout as load

    return load(Path(folder))


class MLXWhisper:
    def __init__(self, repo: str, mode: str):
        sys.path.insert(0, str(REPO))
        from v2t import backends

        self.stt = backends.WhisperSTT(repo)

    def run(self, clip: dict) -> dict:
        t0 = time.perf_counter()
        text = self.stt.transcribe(clip["path"])
        return {"offline": text, "offline_s": time.perf_counter() - t0}

    def decode(self, audio: np.ndarray) -> str:
        return self.stt._mlx_whisper.transcribe(
            audio, path_or_hf_repo=self.stt.model_path
        )["text"].strip()


class ParakeetCoreML:
    """v2t's Core ML decode (backends.ParakeetCoreMLSTT.decode) without the MLX
    model it keeps for the live text; reads FluidAudio's files, never the repo."""

    def __init__(self, repo: str, mode: str):
        sys.path.insert(0, str(REPO))
        from v2t.coreml import CoreMLParakeet

        self.model = CoreMLParakeet()

    def run(self, clip: dict) -> dict:
        audio = load_audio(clip["path"])
        t0 = time.perf_counter()
        text = self.decode(audio)
        return {"offline": text, "offline_s": time.perf_counter() - t0}

    def decode(self, audio: np.ndarray) -> str:
        return self.model.decode(audio)


VAD_FRAME_S = 0.03  # energy frames for speech_segments
VAD_FLOOR_DB = -30  # frames this far below the clip's loudest 1% are silence...
VAD_ABS_DB = -55  # ...and so is any frame under this, whatever the clip (dBFS)
VAD_GAP_S = 0.8  # silences shorter than this stay inside a segment
VAD_PAD_S = 0.2  # kept either side of each segment
VAD_MAX_S = 25  # longer segments are cut at their quietest frame


def speech_segments(audio: np.ndarray) -> list[tuple[int, int]]:
    """(start, end) samples of the speech in a clip, by frame energy.

    A frame is speech when its RMS is within VAD_FLOOR_DB of the clip's 99th
    percentile frame and above VAD_ABS_DB; speech closer than VAD_GAP_S merges, each
    segment is padded and cut to at most VAD_MAX_S at its quietest frame. On the
    2026-10-24 dictations speech sat at -35 to -18 dBFS and a ten-minute near-silent
    clip at -51 dBFS in its loudest 1%.
    """
    hop = int(VAD_FRAME_S * SAMPLE_RATE)
    n = len(audio) // hop
    if n == 0:
        return []
    frames = audio[: n * hop].reshape(n, hop)
    db = 20 * np.log10(np.sqrt((frames**2).mean(axis=1)) + 1e-9)
    speech = np.flatnonzero(db > max(np.percentile(db, 99) + VAD_FLOOR_DB, VAD_ABS_DB))
    if not len(speech):
        return []
    gap, pad = int(VAD_GAP_S / VAD_FRAME_S), int(VAD_PAD_S / VAD_FRAME_S)
    runs, start, prev = [], speech[0], speech[0]
    for f in speech[1:]:
        if f - prev > gap:
            runs.append((start, prev))
            start = f
        prev = f
    runs.append((start, prev))
    longest = int(VAD_MAX_S / VAD_FRAME_S)
    out = []
    for a, b in runs:
        a, b = max(0, a - pad), min(n - 1, b + pad)
        while b - a > longest:
            window = db[a + longest // 2 : a + longest]
            cut = a + longest // 2 + int(np.argmin(window))
            out.append((a * hop, cut * hop))
            a = cut
        out.append((a * hop, (b + 1) * hop))
    return out


class MLXAudio:
    """mlx-audio 0.5.7: `generate` for offline models, a streaming session
    (feed / step / close) for natively streaming ones. A repo ending in `#vad`
    decodes only the speech segments of each clip (speech_segments)."""

    def __init__(self, repo: str, mode: str):
        from mlx_audio.stt import load

        repo, _, flag = repo.partition("#")
        self.vad = flag == "vad"
        self.model = load(repo)
        self.mode = mode
        self.lang = "en"  # the `chunk` sets are English

    def run(self, clip: dict) -> dict:
        self.lang = clip["lang"]
        audio = load_audio(clip["path"])
        if self.mode == "offline":
            t0 = time.perf_counter()
            text = self.decode(audio)
            return {"offline": text, "offline_s": time.perf_counter() - t0}
        return self._stream(audio)

    def decode(self, audio: np.ndarray) -> str:
        if self.vad:
            texts = [self._decode(audio[a:b]) for a, b in speech_segments(audio)]
            return " ".join(t for t in texts if t)
        return self._decode(audio)

    def _decode(self, audio: np.ndarray) -> str:
        if "parakeet" in type(self.model).__name__.lower():
            import mlx.core as mx

            # its generate takes a path or an mx.array; past WHOLE_FILE_MAX_S, its
            # own chunking (2 s overlap, its default)
            long = len(audio) > WHOLE_FILE_MAX_S * SAMPLE_RATE
            return self.model.generate(
                mx.array(audio), chunk_duration=WHOLE_FILE_MAX_S if long else None
            ).text.strip()
        if "cohere" in type(self.model).__module__:
            # no language detection: it must be told (defaults to English)
            return self.model.generate(audio, language=self.lang).text.strip()
        return self.model.generate(audio).text.strip()

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
        stopped = None  # the session ended itself (an end token) before release
        last = max(0, (len(audio) - 1) // feed * feed)  # the push that follows release
        for start in range(0, last, feed):
            t0 = time.perf_counter()
            session.feed(audio[start : start + feed])
            self._drain(session, parts)
            busy += time.perf_counter() - t0
            if stopped is None and session.done:
                stopped = round((start + feed) / SAMPLE_RATE, 1)
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
            "stopped_early_s": stopped,
        }


class Fermion:
    """Phonon-2 through fermion-research's MLX engine, as `fermion transcribe` runs
    it: one decode up to 35 s, longer audio cut at pauses into 25-35 s windows.

    The container is unpacked from the Hugging Face snapshot into
    ~/.v2t/eval/grid-models, so the package's own cache (~/.cache/fermion) is
    never written. `repo#levers` sets FERMION_P2_FAST before loading.
    """

    def __init__(self, repo: str, mode: str):
        repo, _, levers = repo.partition("#")
        if levers:
            os.environ["FERMION_P2_FAST"] = levers
        folder = EVAL / "grid-models" / repo.split("/")[-1].lower()
        if not (folder / "model.fermion").exists():
            from fermion._speech import fetch

            archive = next(Path(_snapshot(repo)).glob("*.tar.zst"))
            fetch._unpack(archive, private_dir(folder.parent) / folder.name)
        import fermion

        self.model = fermion.load_speech(str(folder))

    def run(self, clip: dict) -> dict:
        audio = load_audio(clip["path"])
        t0 = time.perf_counter()
        text = self.decode(audio)
        return {"offline": text, "offline_s": time.perf_counter() - t0}

    def decode(self, audio: np.ndarray) -> str:
        return self.model.transcribe_array(audio)[0].strip()


RUNTIMES = {
    "fermion": Fermion,
    "parakeet-mlx": ParakeetMLX,
    "mlx-whisper": MLXWhisper,
    "mlx-audio": MLXAudio,
    "parakeet-coreml": ParakeetCoreML,
}


def run(system: str, set_name: str, limit: int | None, tag: str | None = None) -> None:
    runtime, repo, mode = SYSTEMS[system]
    if runtime not in RUNTIMES:
        raise SystemExit(f"{system} runs through a local script kept out of the repo: uv run --script .ignored_scripts/wispr_api.py run --set {set_name}")
    if system in ENGLISH_ONLY and set_name == "fleurs-es":
        raise SystemExit(f"{system} is English only")
    clips = read_jsonl(SETS / f"{set_name}.jsonl")
    if not clips:
        raise SystemExit(f"no clips for {set_name}; run `prepare` first")
    # a tagged run (a timing baseline) goes beside the cell, never into it
    out_path = private_dir(RESULTS / set_name) / f"{system}.jsonl{'.' + tag if tag else ''}"
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
    release_cache()
    with out_path.open("a") as out:
        os.chmod(out_path, 0o600)
        for n, clip in enumerate(todo, 1):
            result = {
                "id": clip["id"],
                "duration_s": clip["duration_s"],
                **measured(lambda: engine.run(clip)),
            }
            out.write(json.dumps(result) + "\n")
            out.flush()
            release_cache()
            if n % 10 == 0 or n == len(todo):
                print(f"  {n}/{len(todo)}", flush=True)


# --- chunked: the batch models' version of v2t's 60 s rule ---------------------


def chunk_cuts(audio: np.ndarray) -> list[tuple[int, int]]:
    """Where a recording would be cut while it is still going on.

    Every CHUNK_S, at the quietest 100 ms within CHUNK_SEARCH_S of the mark (the
    splitter mlx-audio's Qwen3-ASR uses for long files). A cut needs the audio up
    to CHUNK_SEARCH_S past its mark, so only the cuts that audio exists for are
    made before release; the rest is one piece decoded after it. Returns
    (cut, sample at which the cut is known) pairs.
    """
    window = SAMPLE_RATE // 10
    search = CHUNK_SEARCH_S * SAMPLE_RATE
    cuts, start = [], 0
    while start + CHUNK_S * SAMPLE_RATE + search <= len(audio):
        lo = start + CHUNK_S * SAMPLE_RATE - search
        region = audio[lo : lo + 2 * search]
        energy = np.convolve(region**2, np.ones(window) / window, mode="valid")
        start = lo + int(np.argmin(energy)) + window // 2
        cuts.append((start, lo + 2 * search))
    return cuts


def chunked(engine, audio: np.ndarray) -> dict:
    """Decode a recording piece by piece as it would arrive, then the rest on release.

    Each piece is decoded once its cut is known; a piece still decoding when the next
    is ready queues behind it. The wait is from release to the last piece's text.
    """
    cuts = chunk_cuts(audio)
    bounds = [0, *(cut for cut, _ in cuts), len(audio)]
    known = [known for _, known in cuts] + [len(audio)]  # the last piece: at release
    texts, finished, busy = [], 0.0, 0.0
    for lo, hi, ready in zip(bounds, bounds[1:], known):
        t0 = time.perf_counter()
        texts.append(engine.decode(audio[lo:hi]))
        took = time.perf_counter() - t0
        busy += took
        finished = max(ready / SAMPLE_RATE, finished) + took
    return {
        "chunked": " ".join(t for t in texts if t),
        "chunked_wait_s": finished - len(audio) / SAMPLE_RATE,
        "chunked_busy_s": busy,
        "pieces": len(bounds) - 1,
    }


def run_chunked(system: str, set_name: str, limit: int | None) -> None:
    runtime, repo, mode = SYSTEMS[system]
    if mode == "stream":
        raise SystemExit(f"{system} streams natively; `chunk` is for whole-file decoders")
    clips = [
        c
        for c in read_jsonl(SETS / f"{set_name}.jsonl")
        if c["duration_s"] >= TAKEOVER_S
    ]
    out_path = private_dir(RESULTS / set_name) / f"{system}.chunked.jsonl"
    done = {r["id"] for r in read_jsonl(out_path)}
    todo = [c for c in clips if c["id"] not in done][:limit]
    print(f"{system} chunked on {set_name}: {len(done)} done, {len(todo)} to go")
    if not todo:
        return
    engine = RUNTIMES[runtime](repo, mode)
    warm = load_audio(min(clips, key=lambda c: c["duration_s"])["path"])
    engine.decode(warm[: CHUNK_S * SAMPLE_RATE])  # warm-up, one piece long
    release_cache()
    with out_path.open("a") as out:
        os.chmod(out_path, 0o600)
        for n, clip in enumerate(todo, 1):
            result = {"id": clip["id"], "duration_s": clip["duration_s"]}
            audio = load_audio(clip["path"])
            result.update(measured(lambda: chunked(engine, audio)))
            out.write(json.dumps(result) + "\n")
            out.flush()
            release_cache()
            if n % 10 == 0 or n == len(todo):
                print(f"  {n}/{len(todo)}", flush=True)


# --- report -------------------------------------------------------------------


CHUNKED = "+chunked"  # a whole-file system scored with its `chunk` pass from 60 s up


def mode_of(system: str) -> str:
    return "chunked" if system.endswith(CHUNKED) else SYSTEMS[system][2]


def final_text(system: str, row: dict) -> str:
    """The text a user would get: v2t's hacky rule, the stream, or the whole file."""
    mode = mode_of(system)
    if mode in ("hacky", "chunked") and row["duration_s"] >= TAKEOVER_S:
        return row["stream" if mode == "hacky" else "chunked"]
    return row["stream"] if mode == "stream" else row["offline"]


def wait_s(system: str, row: dict) -> float:
    mode = mode_of(system)
    if mode in ("hacky", "chunked") and row["duration_s"] >= TAKEOVER_S:
        return row["stream_wait_s" if mode == "hacky" else "chunked_wait_s"]
    return row["stream_wait_s"] if mode == "stream" else row["offline_s"]


def q(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))]


def compute_s(system: str, row: dict) -> float:
    mode = mode_of(system)
    if mode == "chunked":
        return row["chunked_busy_s" if row["duration_s"] >= TAKEOVER_S else "offline_s"]
    if mode == "hacky" and row["duration_s"] < TAKEOVER_S:
        # Older results stored feed + finalisation together; both timings exist.
        feed = row.get("stream_feed_s", row["stream_busy_s"] - row["stream_wait_s"])
        return feed + row["offline_s"]
    return row["offline_s"] if mode == "offline" else row["stream_busy_s"]


def chunked_cells(set_name: str, cells: dict, common: list[str]) -> dict:
    """`<system>+chunked` for each whole-file system whose chunk pass covers the
    common clips from 60 s up: its own rows with the chunked text merged in."""
    out = {}
    for path in sorted((RESULTS / set_name).glob("*.chunked.jsonl")):
        base = path.name.removesuffix(".chunked.jsonl")
        if base not in cells:
            continue
        extra = {r["id"]: r for r in read_jsonl(path)}
        long = [cid for cid in common if cells[base][cid]["duration_s"] >= TAKEOVER_S]
        if not all(cid in extra for cid in long):
            continue  # pass not finished: leave it out rather than score a subset
        out[base + CHUNKED] = {
            cid: {**cells[base][cid], **extra.get(cid, {})} for cid in common
        }
    return out


def family(system: str) -> str:
    """parakeet-v3, its fine-tunes and its low-bit retrains (Ultra, Redux, Phonon-2) are
    one family; so are the two Qwen3-ASR builds."""
    head = system.split("-")[0]
    return "parakeet" if head == "phonon" else head


def incomplete_cells(set_name: str) -> dict[str, tuple[int, int]]:
    """Cells of a set that miss clips of its manifest: system -> (done, total).

    `score_set` scores the clips every cell finished, so one cell cut short (or an
    empty file left by a crash) shrinks or empties every row of the set.
    """
    ids = {c["id"] for c in read_jsonl(SETS / f"{set_name}.jsonl")}
    out = {}
    for path in sorted((RESULTS / set_name).glob("*.jsonl")):
        if path.stem in SYSTEMS:
            done = len(ids & {r["id"] for r in read_jsonl(path)})
            if done < len(ids):
                out[path.stem] = (done, len(ids))
    return out


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
    if not common:
        return []
    # chunked variants are scored like any system but never vote, so adding one
    # leaves every other row unchanged
    scored = {**cells, **chunked_cells(set_name, cells, common)}
    errors = dict.fromkeys(scored, 0)
    words = dict.fromkeys(scored, 0)
    for cid in common:
        clip = clips[cid]
        hyps = {s: normalise(final_text(s, scored[s][cid]), clip["lang"]) for s in scored}
        if clip["text"] is not None:
            ref = normalise(clip["text"], clip["lang"])
            for s in scored:
                errors[s] += edits(ref, hyps[s])
                words[s] += len(ref)
            continue
        # no label: the medoid of the other systems, leaving out the system's own
        # family, whose near-identical text would otherwise vote for it. Wispr's stored
        # text no longer votes: it is its final, often formatted or truncated, output
        voters = {s: hyps[s] for s in cells}
        names = list(voters)
        pair = {
            frozenset((a, b)): edits(voters[a], voters[b])
            for i, a in enumerate(names)
            for b in names[i + 1 :]
        }

        def dist(a: str, b: str) -> int:
            return 0 if a == b else pair[frozenset((a, b))]

        for s in scored:
            others = [n for n in names if family(n) != family(s)]
            if not others:  # a lone system: nothing to agree with
                continue
            ref_name = min(others, key=lambda c: sum(dist(c, o) for o in others))
            errors[s] += edits(voters[ref_name], hyps[s])
            words[s] += len(voters[ref_name])
    rows = []
    for system, rows_by_id in scored.items():
        if not words[system]:
            continue  # no reference words: this cell cannot supply an error rate
        waits = [wait_s(system, rows_by_id[cid]) for cid in common]
        busy = sum(
            compute_s(system, rows_by_id[cid])
            for cid in common
        )
        audio = sum(clips[cid]["duration_s"] for cid in common)
        peaks = [rows_by_id[cid].get("peak_mem_gb") for cid in common]
        rows.append(
            {
                "system": system,
                "mode": mode_of(system),
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
                # recorded since 2026-10-14; older cells have none
                "peak_gb": max(peaks) if None not in peaks else None,
            }
        )
    return sorted(rows, key=lambda r: r["wer"])


WISPR_FLOW = {"wispr-flow": False, "wispr-flow-fallback": True}  # row -> usedFallbackAsr


def score_wispr_flow() -> list[dict]:
    """Wispr Flow's own ASR on the `wispr` set, as rows shaped like `score_set`'s.

    Its transcript is scored against the medoid of every grid system's transcript (it
    never votes for itself), on the clips every cell finished. The clips split on Wispr's
    own `usedFallbackAsr` flag (from the bench export): `wispr-flow` is its normal path,
    `wispr-flow-fallback` the dictations where it fell back to another ASR, which is
    what happens when its websocket is blocked. Wait is Wispr's own `e2eLatency`, stop to
    paste, so it includes its formatting pass; clips without one have no wait.
    """
    clips = {c["id"]: c for c in read_jsonl(SETS / "wispr.jsonl")}
    meta = {r["id"]: r for r in read_jsonl(WISPR / "results.jsonl")}
    every = {
        p.stem: {r["id"]: r for r in read_jsonl(p)}
        for p in sorted((RESULTS / "wispr").glob("*.jsonl"))
        if p.stem in SYSTEMS
    }
    # the clips every cell finished, Wispr's own API cell included, as score_set uses;
    # only the voters leave Wispr out (Wispr never votes for Wispr)
    cells = {name: rows for name, rows in every.items() if family(name) != "wispr"}
    if not cells:
        return []
    common = sorted(
        cid
        for cid in set(clips).intersection(*[set(rows) for rows in every.values()])
        if clips[cid].get("wispr_asr") and cid in meta
    )
    rows = []
    for name, fallback in WISPR_FLOW.items():
        ids = [cid for cid in common if bool(meta[cid].get("wispr_fallback_asr")) == fallback]
        errors = words = 0
        for cid in ids:
            voters = {s: normalise(final_text(s, cells[s][cid]), "en") for s in cells}
            names = list(voters)
            ref = min(names, key=lambda c: sum(edits(voters[c], voters[o]) for o in names if o != c))
            errors += edits(voters[ref], normalise(clips[cid]["wispr_asr"], "en"))
            words += len(voters[ref])
        if not words:
            continue
        waits = [meta[cid]["wispr_e2e_ms"] / 1000 for cid in ids if meta[cid].get("wispr_e2e_ms")]
        rows.append(
            {
                "system": name,
                "mode": "cloud",
                "n": len(ids),
                "errors": errors,
                "words": words,
                "wer": errors / words,
                "waits": waits,
                "wait_p50": q(waits, 0.5) if waits else float("nan"),
                "wait_p90": q(waits, 0.9) if waits else float("nan"),
                "wait_max": max(waits) if waits else float("nan"),
                "busy_s": float("nan"),
                "audio_s": sum(clips[cid]["duration_s"] for cid in ids),
                "rtf": float("nan"),
                "peak_gb": None,
            }
        )
    return rows


def report() -> None:
    lines = [f"# ASR grid, {date.today().isoformat()}", ""]
    lines.append(
        "WER: labelled sets against their references; `wispr` against the leave-one-out "
        "consensus of the other systems (agreement, not truth). Wait: "
        "seconds from release to final text. RTF: compute / audio. Peak: MLX's peak "
        "memory on the worst clip, weights included (cells from 2026-10-14 on)."
    )
    for set_path in sorted(SETS.glob("*.jsonl")):
        rows = score_set(set_path.stem)
        if not rows:
            continue
        lines += [
            "",
            f"## {set_path.stem} ({rows[0]['n']} clips)",
            "",
            "| system | mode | WER | wait p50 | p90 | max | RTF | peak |",
            "|---|---|--:|--:|--:|--:|--:|--:|",
        ]
        for r in rows:
            peak = "–" if r["peak_gb"] is None else f"{r['peak_gb']:.2f} GB"
            lines.append(
                f"| {r['system']} | {r['mode']} | {r['wer']:.1%} | {r['wait_p50']:.2f}s "
                f"| {r['wait_p90']:.2f}s | {r['wait_max']:.2f}s | {r['rtf']:.3f} | {peak} |"
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
    r.add_argument("--tag", help="write <system>.jsonl.<tag>, which the report ignores")
    c = sub.add_parser("chunk", help="a whole-file system, piece by piece, on clips from 60 s")
    c.add_argument("--system", choices=sorted(SYSTEMS), required=True)
    c.add_argument("--set", dest="set_name", required=True)
    c.add_argument("--limit", type=int)
    sub.add_parser("report")
    a = p.parse_args(argv)
    private_dir(GRID)
    if a.command == "prepare":
        prepare()
    elif a.command == "run":
        run(a.system, a.set_name, a.limit, a.tag)
    elif a.command == "chunk":
        run_chunked(a.system, a.set_name, a.limit)
    else:
        report()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
