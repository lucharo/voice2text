"""Parakeet v3 on Core ML (the Neural Engine), for the `parakeet-coreml` backend.

FluidAudio's compiled model files run through coremltools, with greedy TDT decoding
written here; no Swift. Only whole-audio decoding: the encoder takes a fixed 15 s
window, so the live text while the key is held stays on MLX (backends.ParakeetStream).

Measured on an M4 Pro, 2026-10-15 (#52, #55): on 450 labelled clips (LibriSpeech
clean and other, FLEURS Spanish) 2.00 / 4.66 / 5.67% WER against 2.03 / 4.28 / 5.40%
for MLX 8-bit; the wait after release 0.66x MLX's (per-clip median ratio,
interleaved in one process), shorter on 96% of clips; loads in 0.4 s.

The pure parts (`tdt_greedy`, `detokenize`, the window cutting through PieceDecoder)
need neither coremltools nor the model files, so the tests run without them.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

import numpy as np

from .backends import PieceDecoder

# Where FluidAudio keeps the files it downloads from Hugging Face
# (FluidInference/parakeet-tdt-0.6b-v3-coreml); v2t reads them, never fetches them.
COREML_DIR = (
    Path.home() / "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
)
FILES = (
    "Preprocessor.mlmodelc",
    "Encoder_v2.mlmodelc",
    "Decoder.mlmodelc",
    "JointDecisionv3.mlmodelc",
    "parakeet_v3_vocab.json",
)
SAMPLE_RATE = 16000
WINDOW = 240000  # the Preprocessor's input is fixed at 1 x 240000 samples, 15 s
BLANK = 8192  # the TDT blank, which also starts the decoder off
MAX_SYMBOLS = 10  # tokens per encoder frame before forcing a step (FluidAudio's TdtConfig)
DECODER_STATE = (2, 1, 640)  # the prediction network's LSTM h and c
# Audio over one window is cut at the quietest 0.1 s within PIECE_SEARCH_S of every
# PIECE_S mark (PieceDecoder's rule), so no piece is longer than PIECE_S +
# PIECE_SEARCH_S = WINDOW. On 40 recordings of 65-286 s this gave 2.45% WER (#52).
PIECE_S = 12.0
PIECE_SEARCH_S = 3.0

Predict = Callable[[int, object], tuple[object, object]]
Joint = Callable[[int, object], tuple[int, int]]


def tdt_greedy(
    frames: int,
    joint: Joint,
    predict: Predict,
    state: object,
    blank: int = BLANK,
    max_symbols: int = MAX_SYMBOLS,
) -> list[int]:
    """Greedy TDT decoding over `frames` encoder frames; the token ids emitted.

    `predict(token, state)` runs the prediction network on one token and returns
    (output, new state); `joint(t, output)` scores encoder frame `t` against that
    output and returns (token, duration in frames). A blank never feeds the
    prediction network back. A duration of 0 stays on the frame for another token,
    except after a blank or `max_symbols` tokens on one frame, where it moves on one.
    """
    out, state = predict(blank, state)  # the blank doubles as start-of-sequence
    tokens: list[int] = []
    t = emitted = 0
    while t < frames:
        token, duration = joint(t, out)
        if token != blank:
            tokens.append(token)
            out, state = predict(token, state)
            emitted += 1
        if duration == 0 and (token == blank or emitted >= max_symbols):
            duration = 1
        if duration > 0:
            emitted = 0
        t += duration
    return tokens


def detokenize(tokens: list[int], vocab: dict[int, str]) -> str:
    """SentencePiece pieces to text: '▁' marks the start of a word."""
    return "".join(vocab.get(i, "") for i in tokens).replace("\u2581", " ").strip()


def missing_files(folder: Path) -> list[str]:
    return [name for name in FILES if not (folder / name).exists()]


class CoreMLParakeet:
    """Parakeet v3's four Core ML models; `decode(audio)` for 16 kHz float32 audio.

    The Preprocessor (log-mel) runs on the CPU, the encoder, decoder and joint on
    the CPU and Neural Engine.
    """

    def __init__(self, folder: Path = COREML_DIR):
        missing = missing_files(folder)
        if missing:
            raise SystemExit(
                f"parakeet-coreml needs FluidAudio's Parakeet v3 Core ML files in "
                f"{folder}, missing: {', '.join(missing)}. Put the contents of "
                "huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml there "
                "(any FluidAudio app downloads them to that folder), or set "
                'backend = "parakeet".'
            )
        try:
            import coremltools as ct
        except ImportError as e:
            raise SystemExit(
                "parakeet-coreml needs coremltools: uv tool install 'voice2text[coreml]'"
            ) from e
        model, units = ct.models.CompiledMLModel, ct.ComputeUnit
        self.pre = model(str(folder / FILES[0]), compute_units=units.CPU_ONLY)
        self.enc = model(str(folder / FILES[1]), compute_units=units.CPU_AND_NE)
        self.dec = model(str(folder / FILES[2]), compute_units=units.CPU_AND_NE)
        self.joint = model(str(folder / FILES[3]), compute_units=units.CPU_AND_NE)
        vocab = json.loads((folder / FILES[4]).read_text())
        self.vocab = {int(k): v for k, v in vocab.items()}

    def decode(self, audio: np.ndarray) -> str:
        """Text for 16 kHz float32 audio of any length, one window per piece."""
        pieces = PieceDecoder(self.window, SAMPLE_RATE, PIECE_S, PIECE_SEARCH_S)
        pieces.add(audio)
        return pieces.finish()

    def window(self, pcm: np.ndarray) -> str:
        """Text for at most one WINDOW of audio, zero-padded to it."""
        if pcm.size > WINDOW:
            raise ValueError(f"{pcm.size} samples is over the {WINDOW}-sample window")
        x = np.zeros((1, WINDOW), np.float32)
        x[0, : pcm.size] = pcm
        mel = self.pre.predict(
            {"audio_signal": x, "audio_length": np.array([pcm.size], np.int32)}
        )
        enc = self.enc.predict(
            {"mel": mel["mel"], "mel_length": mel["mel_length"].astype(np.int32)}
        )
        frames = enc["encoder"]

        def joint(t: int, out) -> tuple[int, int]:
            j = self.joint.predict(
                {"encoder_step": frames[:, :, t : t + 1], "decoder_step": out}
            )
            return int(j["token_id"].reshape(-1)[0]), int(j["duration"].reshape(-1)[0])

        def predict(token: int, state):
            h, c = state
            o = self.dec.predict(
                {
                    "targets": np.array([[token]], np.int32),
                    "target_length": np.array([1], np.int32),
                    "h_in": h,
                    "c_in": c,
                }
            )
            return o["decoder"], (o["h_out"], o["c_out"])

        zeros = np.zeros(DECODER_STATE, np.float32)
        tokens = tdt_greedy(
            int(enc["encoder_length"].reshape(-1)[0]), joint, predict, (zeros, zeros)
        )
        return detokenize(tokens, self.vocab)
