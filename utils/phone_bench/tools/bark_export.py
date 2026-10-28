"""Flatten Bark 3.0's decoder.npz into one float32 blob plus an index for the Swift port, and copy its vocab.

    uv run --with numpy tools/bark_export.py <Underdog-Bark-3.0>/coreml/ane Res/bark

The Core ML encoder (BarkEncoder.mlmodelc) is copied into Res/bark as is.
"""
import json
import shutil
import sys
from pathlib import Path

import numpy as np

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
z = np.load(src / "decoder.npz")


def weight(k: str) -> np.ndarray:
    """int8 weights carry a per-row scale; the Swift decoder reads plain float32."""
    if k + ".q" in z:
        return z[k + ".q"].astype(np.float32) * z[k + ".s"].astype(np.float32)[:, None]
    return z[k].astype(np.float32)


names = ["decoder.embedding.weight", "decoder.decoder_projector.weight", "decoder.decoder_projector.bias",
         "joint.head.weight", "joint.head.bias", "mel_filters"]
for i in range(2):
    names += [f"decoder.lstm.weight_ih_l{i}", f"decoder.lstm.weight_hh_l{i}", f"decoder.lstm.bias_ih_l{i}", f"decoder.lstm.bias_hh_l{i}"]
index, off = {}, 0
with open(dst / "decoder.f32", "wb") as f:
    for n in names:
        a = np.ascontiguousarray(weight(n))
        f.write(a.tobytes())
        index[n] = {"offset": off, "shape": list(a.shape)}
        off += a.size
(dst / "decoder.json").write_text(json.dumps(index))
shutil.copy(src / "vocab.json", dst / "vocab.json")
print({k: v["shape"] for k, v in index.items()})
