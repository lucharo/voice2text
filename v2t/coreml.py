"""Parakeet v3 on Core ML (the Neural Engine), for the `parakeet-coreml` backend.

FluidAudio's compiled model files run through coremltools, with greedy TDT decoding
written here; no Swift, no MLX. The encoder takes one fixed 15 s window, so audio is
decoded in pieces of at most one window, cut at quiet moments; the live text while
the key is held is those pieces plus a decode of the audio after the last one
(backends.ParakeetCoreMLSTT.pieces, app.process_live).

Measured on an M4 Pro (#56): on 450 labelled clips (LibriSpeech clean and other,
FLEURS Spanish) 2.00 / 4.66 / 5.67% WER against 2.03 / 4.28 / 5.40% for MLX 8-bit,
the decode 0.64x MLX's (per-clip median ratio, interleaved), shorter on every clip;
peak memory 0.34 GB against 2.6 GB. The four models load in 0.1 to 0.3 s once
compiled; `import coremltools` adds 1.3 to 1.6 s, as it also imports scikit-learn,
which parakeet-mlx's librosa installs (and torch when that is installed).

The pure parts (`tdt_greedy`, `detokenize`, the window cutting through PieceDecoder)
need neither coremltools nor the model files, so the tests run without them.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

import numpy as np

from .backends import PieceDecoder

# The compiled models on Hugging Face. v2t downloads only the files in FILES (about
# 0.63 GB of the repo's 3.6 GB) into the Hugging Face cache, unless FluidAudio has
# already put them in its own folder, which is read first.
COREML_REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
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


def model_folder(folder: Path | None = None) -> Path:
    """Where the Core ML files are: `folder` when given, else FluidAudio's folder when
    complete, else the Hugging Face cache, downloading just FILES the first time."""
    if folder is not None:
        return folder
    if not missing_files(COREML_DIR):
        return COREML_DIR
    from huggingface_hub import snapshot_download

    from .backends import load_cache_first

    patterns = [f"{name}/*" if name.endswith(".mlmodelc") else name for name in FILES]
    return Path(load_cache_first(COREML_REPO, lambda: snapshot_download(COREML_REPO, allow_patterns=patterns)))


def _import_coremltools():
    """coremltools without the converters' optional backends.

    `import coremltools` imports transformers, torch and scikit-learn whenever they
    are installed, for converting models, which v2t never does; on a fresh install
    (mlx-lm brings transformers, librosa scikit-learn) that took 5.0 to 5.2 s against
    1.3 to 1.6 s with them hidden (2026-10-26). They are hidden only during the import
    and stay importable afterwards (the cleanup's mlx-lm needs transformers).
    """
    import sys

    hidden = [name for name in ("transformers", "torch", "sklearn") if name not in sys.modules]
    for name in hidden:
        sys.modules[name] = None  # an import of it now raises ImportError
    try:
        import coremltools
    finally:
        for name in hidden:
            if sys.modules.get(name) is None:
                del sys.modules[name]
    return coremltools


class CoreMLParakeet:
    """Parakeet v3's four Core ML models; `decode(audio)` for 16 kHz float32 audio.

    The Preprocessor (log-mel) runs on the CPU, the encoder, decoder and joint on
    the CPU and Neural Engine.
    """

    def __init__(self, folder: Path = COREML_DIR):
        missing = missing_files(folder)
        if missing:
            raise SystemExit(
                f"parakeet-coreml needs Parakeet v3's Core ML files in {folder}, missing: "
                f"{', '.join(missing)}. Leave transcription.model blank to download them "
                f"from huggingface.co/{COREML_REPO}, or set backend = \"parakeet\"."
            )
        try:
            ct = _import_coremltools()
        except ImportError as e:
            raise SystemExit(
                "parakeet-coreml needs coremltools: reinstall voice2text (uv tool install --reinstall voice2text)"
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
        """Text for at most one WINDOW of audio, zero-padded to it (numpy refuses more)."""
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
