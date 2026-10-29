"""NVIDIA Nemotron-Labs Unified ASR 0.6B, streaming, for the live preview only (#19).

`transcription.preview = "nemotron"` shows the words while the key is held from this
model instead of the backend's own previews; the pasted text still comes from the
backend (whole-file or pieces, app.process_live). It runs FluidInference's Core ML
conversion through coremltools, ported from FluidAudio's StreamingUnifiedAsrManager
(FluidAudio 55f65d9, FluidInference/FluidAudio#1071): a stateless encoder re-run over
a [left | chunk | right] window of 70 / 7 / 7 encoder frames of 80 ms, with the
chunked attention mask baked in, a greedy RNNT decoder whose LSTM state carries over,
and the language prompt as the encoder's `prompt_id`. Each step adds 7 frames
(0.56 s) of text, 1.12 s behind the speech.

Measured in #85 (M4 Pro, FluidAudio's own Swift, fp16 encoder): labelled WER 1.71 /
4.06 / 5.21 / 9.08 / 32.18% on LibriSpeech clean and other, FLEURS Spanish,
Earnings22 and AMI, against 1.71 / 3.95 / 5.45 / 10.75 / 32.94% for the Parakeet
stream it replaces as the preview; 35 to 47 ms per step. The pure parts (`log_mel`,
`Windower`, `rnnt_greedy`, `detokenize`) need neither coremltools nor the model files.
"""

from __future__ import annotations

import json
import time
import types
from pathlib import Path
from typing import Callable

import numpy as np

REPO = "FluidInference/nemotron-labs-unified-asr-0.6b-coreml"
REVISION = "bd13ddde81d3134719c520845346b3252daf3175"
SUBFOLDER = "coreml"
# FluidAudio keeps its copy here; read first, as coreml.py does for Parakeet v3
FLUIDAUDIO_DIR = (
    Path.home()
    / "Library/Application Support/FluidAudio/Models/nemotron-labs-unified-asr-0.6b-coreml"
    / SUBFOLDER
)
LEFT, CHUNK, RIGHT = 70, 7, 7  # encoder frames: 5.6 s / 0.56 s / 0.56 s
ENCODER = f"nemotron_unified_encoder_streaming_{LEFT}_{CHUNK}_{RIGHT}.mlmodelc"  # fp16
FILES = (
    ENCODER,
    "nemotron_unified_decoder.mlmodelc",
    "nemotron_unified_joint_decision_single_step.mlmodelc",
    "vocab.json",
    "metadata.json",
)
SAMPLE_RATE = 16000
FRAME = 1280  # samples per encoder frame (80 ms)
HOP, N_FFT, WIN, N_MELS = 160, 512, 400, 128
PREEMPH = 0.97
LOG_GUARD = 2.0**-24
BLANK = 4095
MAX_SYMBOLS = 10  # tokens per encoder frame (FluidAudio's maxSymbolsPerFrame)
DECODER_STATE = (2, 1, 640)
AUTO = 127  # the prompt for the model's own language ID
# Prompt ids from the checkpoint's prompt_dictionary (metadata.json), as FluidAudio's
# NemotronUnifiedLanguage has them.
LANGUAGES = {
    "auto": AUTO, "en": 0, "es": 3, "fr": 8, "de": 9, "ru": 11, "pt": 13, "it": 15,
    "nl": 16, "pl": 17, "uk": 19, "ro": 20, "el": 21, "cs": 22, "hu": 23, "sv": 24,
    "da": 25, "fi": 26, "sk": 28, "hr": 29, "bg": 30, "lt": 31, "et": 60, "lv": 61,
    "sl": 62, "mt": 102,
}

Predict = Callable[[int, object], tuple[object, object]]
Joint = Callable[[int, object], int]


def _slaney_filterbank() -> np.ndarray:
    """[N_MELS, N_FFT/2 + 1] triangular mel filters, Slaney scale and norm (librosa's)."""
    f_sp, min_log_hz = 200.0 / 3.0, 1000.0
    min_log_mel, log_step = min_log_hz / f_sp, np.log(6.4) / 27.0

    def hz_to_mel(hz):
        return np.where(hz >= min_log_hz, min_log_mel + np.log(np.maximum(hz, 1e-10) / min_log_hz) / log_step, hz / f_sp)

    def mel_to_hz(mel):
        return np.where(mel >= min_log_mel, min_log_hz * np.exp(log_step * (mel - min_log_mel)), f_sp * mel)

    points = mel_to_hz(np.linspace(hz_to_mel(np.array(0.0)), hz_to_mel(np.array(SAMPLE_RATE / 2)), N_MELS + 2))
    freqs = np.arange(N_FFT // 2 + 1) * SAMPLE_RATE / N_FFT
    left, center, right = points[:-2, None], points[1:-1, None], points[2:, None]
    rising = (freqs >= left) & (freqs < center)
    falling = (freqs >= center) & (freqs <= right)
    bank = np.where(rising, (freqs - left) / (center - left), 0.0)
    bank = np.where(falling, (right - freqs) / (right - center), bank)
    return (bank * 2.0 / (right - left)).astype(np.float32)


_FILTERS = _slaney_filterbank()
_HANN = (0.5 * (1 - np.cos(2 * np.pi * np.arange(WIN) / (WIN - 1)))).astype(np.float32)


def log_mel(window: np.ndarray, valid: int) -> tuple[np.ndarray, np.ndarray]:
    """NeMo's log-mel of one zero-padded encoder window, as FluidAudio computes it.

    Pre-emphasis seeded with 0, centre padding of N_FFT/2 zeros, a symmetric 400-sample
    Hann window inside a 512-point FFT, power, Slaney mel, log(x + 2^-24), then each mel
    bin standardised over the `valid // HOP` real frames (unbiased std + 1e-5) and the
    rest zeroed. Returns `mel` [1, N_MELS, frames] float32 and its valid length [1] int32.
    """
    x = np.asarray(window, dtype=np.float32)
    frames = x.size // HOP + 1
    padded = np.zeros(x.size + N_FFT, np.float32)
    padded[N_FFT // 2] = x[0]
    padded[N_FFT // 2 + 1 : N_FFT // 2 + x.size] = x[1:] - PREEMPH * x[:-1]
    offset = (N_FFT - WIN) // 2
    starts = np.arange(frames) * HOP + offset
    buf = np.zeros((frames, N_FFT), np.float32)
    buf[:, offset : offset + WIN] = padded[starts[:, None] + np.arange(WIN)] * _HANN
    spectrum = np.fft.rfft(buf, axis=1)
    power = (spectrum.real**2 + spectrum.imag**2).astype(np.float32)
    mel = np.log(power @ _FILTERS.T + LOG_GUARD)  # [frames, N_MELS]
    n = min(valid // HOP, frames)
    out = np.zeros_like(mel)
    if n > 0:
        real = mel[:n]
        mean = real.mean(axis=0)
        std = np.sqrt(((real - mean) ** 2).sum(axis=0) / max(n - 1, 1)) + 1e-5
        out[:n] = (real - mean) / std
    return np.ascontiguousarray(out.T[None], dtype=np.float32), np.array([n], np.int32)


class Windower:
    """Which audio each streaming step encodes and which encoder frames it decodes.

    FluidAudio's UnifiedStreamingWindower: the first step waits for chunk + right
    samples, each later one for a chunk; a step encodes the last window ending at the
    audio consumed so far and decodes every frame not decoded yet but the right
    context, which the next step re-encodes with more audio after it. `final` flushes.
    """

    def __init__(self, left: int = LEFT, chunk: int = CHUNK, right: int = RIGHT):
        self.window = (left + chunk + right) * FRAME
        self.chunk, self.right = chunk * FRAME, right * FRAME
        self.right_frames = right
        self.consumed = 0  # samples fed to the encoder so far
        self.decoded = 0  # encoder frames decoded so far
        self.flushed = False

    def next(self, total: int, final: bool = False) -> tuple[int, int, int] | None:
        """(start, end, holdback frames) of the next window, or None for none yet."""
        if self.flushed:
            return None
        feed = self.chunk + self.right if self.consumed == 0 else self.chunk
        if self.consumed + feed <= total:
            end = self.consumed + feed
        elif final and total > 0 and total >= self.consumed:
            end = total  # the rest, or a re-encode of the held-back right context
        else:
            return None
        last = final and end >= total
        self.flushed = last
        start = max(0, end - self.window)
        start += (FRAME - start % FRAME) % FRAME  # frame-aligned, never over a window
        self.consumed = end
        return start, end, 0 if last else self.right_frames

    def frames(self, encoded: int, start: int, holdback: int) -> range | None:
        """The window's local encoder frames to decode, given its valid length."""
        lo = self.decoded - start // FRAME
        hi = encoded - holdback
        if hi <= lo or lo < 0:
            return None
        self.decoded += hi - lo
        return range(lo, hi)


def rnnt_greedy(
    frames: range,
    joint: Joint,
    predict: Predict,
    token: int,
    state: object,
    blank: int = BLANK,
    max_symbols: int = MAX_SYMBOLS,
) -> tuple[list[int], int, object]:
    """Greedy RNNT over encoder `frames`; (tokens, last token, state) to carry on.

    `predict(token, state)` runs the prediction network and returns (output, state after
    that token); `joint(t, output)` returns the best token for frame `t`. `state` is the
    LSTM state before `token` was consumed, as FluidAudio keeps it, so each pass starts by
    running `token` again; it moves on only when a token is emitted.
    """
    out, after = predict(token, state)
    tokens: list[int] = []
    for t in frames:
        for _ in range(max_symbols):
            best = joint(t, out)
            if best == blank:
                break
            tokens.append(best)
            token, state = best, after
            out, after = predict(token, state)
    return tokens, token, state


def detokenize(tokens: list[int], vocab: dict[int, str]) -> str:
    """SentencePiece pieces to text: '▁' marks the start of a word (not stripped)."""
    return "".join(vocab.get(i, "") for i in tokens).replace("\u2581", " ")


def missing_files(folder: Path) -> list[str]:
    return [name for name in FILES if not (folder / name).exists()]


def model_folder() -> Path:
    """FluidAudio's copy when complete, else the Hugging Face cache at REVISION,
    downloading only FILES (about 1.2 GB) the first time."""
    if not missing_files(FLUIDAUDIO_DIR):
        return FLUIDAUDIO_DIR
    from huggingface_hub import snapshot_download

    from .backends import load_cache_first

    patterns = [
        f"{SUBFOLDER}/{name}/*" if name.endswith(".mlmodelc") else f"{SUBFOLDER}/{name}"
        for name in FILES
    ]

    def fetch() -> Path:
        folder = Path(snapshot_download(REPO, revision=REVISION, allow_patterns=patterns)) / SUBFOLDER
        missing = missing_files(folder) + [
            name for name in FILES
            if name.endswith(".mlmodelc") and not (folder / name / "coremldata.bin").exists()
        ]
        if missing:
            raise FileNotFoundError(f"{folder} lacks {', '.join(missing)}")
        return folder

    return load_cache_first(REPO, fetch)


class NemotronStream:
    """The streaming models, loaded once; `start()` before each recording, then
    `add(audio)` as it arrives and `step()` to decode what it allows into `text`.

    The encoder runs on all compute units, as FluidAudio runs the fp16 encoder; the
    decoder and joint on the CPU. The Neural Engine sometimes gives up on a streaming
    prediction ("ANE op async execution has timed out", #85): the encoder is then
    loaded again and the step retried once.
    """

    def __init__(self, folder: Path | None = None, language: str = "auto"):
        from .coreml import CoreMLParakeet, _import_coremltools

        # Core ML's late release of input arrays crashes Python 3.12+ (coremltools 9.0,
        # v2t #66): borrow CoreMLParakeet's guard, which keeps each input referenced.
        self._predict = types.MethodType(CoreMLParakeet._predict, self)
        self._release_held = types.MethodType(CoreMLParakeet._release_held, self)

        folder = folder or model_folder()
        missing = missing_files(folder)
        if missing:
            raise FileNotFoundError(f"Nemotron preview needs {', '.join(missing)} in {folder}")
        ct = _import_coremltools()
        self._ct, self.folder = ct, folder
        self._held: dict[int, np.ndarray] = {}
        self.prompt = np.array([LANGUAGES[language]], np.int32)
        self.enc = self._load_encoder()
        cpu = ct.ComputeUnit.CPU_ONLY
        self.dec = ct.models.CompiledMLModel(str(folder / FILES[1]), compute_units=cpu)
        self.joint = ct.models.CompiledMLModel(str(folder / FILES[2]), compute_units=cpu)
        vocab = json.loads((folder / "vocab.json").read_text())
        self.vocab = {int(k): v for k, v in vocab.items()}
        self.retries = 0  # encoder reloads after a failed prediction, for the log
        self.step_s: list[float] = []  # each step that ran the encoder, this recording
        self.start()

    def _load_encoder(self):
        ct = self._ct
        return ct.models.CompiledMLModel(str(self.folder / ENCODER), compute_units=ct.ComputeUnit.ALL)

    def start(self) -> None:
        """Forget the last recording: no audio, no text, the decoder at its start."""
        self.windower = Windower()
        self._audio: list[np.ndarray] = []
        self._start = 0  # global sample index of the first sample kept
        self._samples = 0  # samples added so far
        self.token = BLANK
        zeros = np.zeros(DECODER_STATE, np.float32)
        self.state = (zeros, zeros)
        self.tokens: list[int] = []
        self._text = ""
        self.step_s = []

    @property
    def text(self) -> str:
        return self._text.strip()

    def add(self, audio: np.ndarray) -> None:
        flat = np.asarray(audio, dtype=np.float32).reshape(-1)
        if flat.size:
            self._audio.append(flat)
            self._samples += flat.size

    def step(self, final: bool = False) -> bool:
        """Run every window the audio added so far allows; True when the text grew."""
        before = len(self.tokens)
        while plan := self.windower.next(self._samples, final):
            t0 = time.perf_counter()
            self._window(*plan)
            self.step_s.append(time.perf_counter() - t0)
            self._trim()
        return len(self.tokens) > before

    def _kept(self) -> np.ndarray:
        if len(self._audio) > 1:
            self._audio = [np.concatenate(self._audio)]
        return self._audio[0] if self._audio else np.zeros(0, np.float32)

    def _trim(self) -> None:
        """Drop audio no later window can reach (FluidAudio's trimSamples)."""
        keep_from = self.windower.consumed - self.windower.window
        if keep_from > self._start:
            self._audio = [self._kept()[keep_from - self._start :]]
            self._start = keep_from

    def _encode(self, mel: np.ndarray, length: np.ndarray) -> dict:
        inputs = {"mel": mel, "mel_length": length, "prompt_id": self.prompt}
        try:
            return self._predict(self.enc, inputs)
        except Exception:
            self.enc = self._load_encoder()  # a timed-out ANE program: start afresh
            self.retries += 1
            return self._predict(self.enc, inputs)

    def _window(self, start: int, end: int, holdback: int) -> None:
        self._release_held()
        window = np.zeros(self.windower.window, np.float32)
        audio = self._kept()[start - self._start : end - self._start]
        window[: audio.size] = audio
        mel, length = log_mel(window, audio.size)
        enc = self._encode(mel, length)
        encoded = enc["encoder"]
        valid = min(int(enc["encoder_length"].reshape(-1)[0]), encoded.shape[2])
        frames = self.windower.frames(valid, start, holdback)
        if frames is None:
            return

        def joint(t: int, out) -> int:
            j = self._predict(self.joint, {"encoder_step": encoded[:, :, t : t + 1], "decoder_step": out})
            return int(j["token_id"].reshape(-1)[0])

        def predict(token: int, state):
            h, c = state
            o = self._predict(
                self.dec,
                {
                    "targets": np.array([[token]], np.int32),
                    "target_length": np.array([1], np.int32),
                    "h_in": h,
                    "c_in": c,
                },
            )
            return o["decoder"], (o["h_out"], o["c_out"])

        tokens, self.token, self.state = rnnt_greedy(frames, joint, predict, self.token, self.state)
        self.tokens += tokens
        self._text += detokenize(tokens, self.vocab)

    def transcribe(self, audio: np.ndarray) -> str:
        """The whole of `audio` streamed step by step (for the bench and tests)."""
        self.start()
        self.add(audio)
        self.step(final=True)
        return self.text
