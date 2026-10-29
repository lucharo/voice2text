#!/usr/bin/env python3
"""Stage the app's bundled resources into utils/phone_bench/Res and check them against res-manifest.json.

The clips, cleanup inputs and Core ML models are not committed. res-manifest.json pins each file by SHA-256,
so any copy of the 2026-10-27 bench resources can be staged and proven identical:

    ./stage.py --from /path/to/Res          # copy, then verify
    ./stage.py                              # verify what is already staged
    ./stage.py --write-manifest --from DIR  # maintainers: re-pin after changing the resources

Res/clips     450 speech clips, 16 kHz mono WAV, plus manifest.tsv (id, file, seconds): 150 each of
              LibriSpeech test-clean and test-other and FLEURS es, from the ASR grid's sample sets.
Res/cleanup   inputs.jsonl (600 Parakeet v3 transcripts in chunks, 150 each of LibriSpeech clean and other,
              AMI SDM and Earnings-22), chat.json (the MLX/ANEMLL prompt), instructions.txt (Apple's).
Res/models    Parakeet TDT v3 Core ML models for FluidAudio (int8 encoder, Encoder_v2.mlmodelc).
Res/bark      Bark 3.0's Core ML encoder plus the decoder blob made by tools/bark_export.py.
"""
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RES = HERE / "Res"
MANIFEST = HERE / "res-manifest.json"
PARTS = ("clips", "cleanup", "models", "bark")


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def files(root: Path) -> dict[str, Path]:
    return {str(p.relative_to(root)): p for part in PARTS for p in sorted((root / part).rglob("*"))
            if p.is_file() and p.name != ".DS_Store"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", type=Path, help="a Res folder to copy clips/, cleanup/, models/, bark/ from")
    ap.add_argument("--write-manifest", action="store_true", help="re-pin res-manifest.json from the staged files")
    a = ap.parse_args()
    if a.src and any((a.src / p).resolve() == (RES / p).resolve() for p in PARTS):
        sys.exit(f"{a.src} is (or links into) Res itself; nothing to copy")
    if a.src:
        missing = [p for p in PARTS if not (a.src / p).is_dir()]
        if missing:
            sys.exit(f"{a.src} lacks {', '.join(missing)}")
        for p in PARTS:
            if (RES / p).exists():
                shutil.rmtree(RES / p)
            shutil.copytree(a.src / p, RES / p, ignore=shutil.ignore_patterns(".DS_Store"))
        print(f"copied {', '.join(PARTS)} from {a.src}")
    have = files(RES)
    if a.write_manifest:
        MANIFEST.write_text(json.dumps({k: sha256(p) for k, p in have.items()}, indent=1, sort_keys=True) + "\n")
        print(f"pinned {len(have)} files in {MANIFEST.name}")
        return 0
    want = json.loads(MANIFEST.read_text())
    bad = [k for k in want if k not in have or sha256(have[k]) != want[k]]
    extra = sorted(set(have) - set(want))
    for k in bad:
        print(f"{'differs' if k in have else 'missing'}: Res/{k}")
    for k in extra:
        print(f"not in manifest: Res/{k}")
    print(f"{len(want) - len(bad)}/{len(want)} files match res-manifest.json" + (f", {len(extra)} extra" if extra else ""))
    return 1 if bad or extra else 0


if __name__ == "__main__":
    sys.exit(main())
