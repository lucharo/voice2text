"""Speech-to-text backends (MLX) and text cleanup (Ollama).

STT is pluggable so models are easy to switch; Parakeet is the default because
it's the fastest thing on Apple Silicon right now. Heavy MLX imports are lazy so
`v2t config`/`v2t bench --cleanup` work without a GPU model loaded.
"""

from __future__ import annotations

import json
import re
import subprocess
import time
import urllib.error
import urllib.request

PARAKEET_DEFAULT = "mlx-community/parakeet-tdt-0.6b-v3"
WHISPER_DEFAULT = "mlx-community/whisper-large-v3-turbo"


class ParakeetSTT:
    default_model = PARAKEET_DEFAULT

    def __init__(self, model: str = ""):
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as e:
            raise SystemExit("parakeet backend needs: uv tool install 'voice2text[parakeet]' (Apple Silicon).") from e
        self.model = from_pretrained(model or self.default_model)

    def transcribe(self, wav_path: str) -> str:
        return self.model.transcribe(wav_path).text.strip()


class WhisperSTT:
    default_model = WHISPER_DEFAULT

    def __init__(self, model: str = ""):
        try:
            import mlx_whisper
        except ImportError as e:
            raise SystemExit("whisper backend needs: uv tool install 'voice2text[whisper]'") from e
        self._mlx_whisper = mlx_whisper
        self.model = model or self.default_model

    def transcribe(self, wav_path: str) -> str:
        return self._mlx_whisper.transcribe(wav_path, path_or_hf_repo=self.model)["text"].strip()


STT = {"parakeet": ParakeetSTT, "whisper": WhisperSTT}


def make_stt(backend: str, model: str = ""):
    if backend not in STT:
        raise SystemExit(f"unknown backend {backend!r}; choose: {', '.join(STT)}")
    return STT[backend](model)


PROMPTS = {
    "strict": (
        "Clean up this transcription. Fix punctuation, remove filler words "
        "(um, uh, like, you know), fix obvious mishearings, keep the meaning intact. "
        "Output ONLY the cleaned text, nothing else:\n\n{text}"
    ),
    "casual": (
        "Lightly clean up this transcription. Only fix punctuation and remove filler "
        "words (um, uh, like, you know). Do NOT restructure sentences or change word "
        "order. Keep the original phrasing. Output ONLY the cleaned text, nothing "
        "else:\n\n{text}"
    ),
}

_THINK = re.compile(r"<think>.*?</think>", re.DOTALL)


def cleanup(text: str, model: str, mode: str = "strict", url: str = "http://localhost:11434", timeout: int = 60):
    """Clean a transcription with a local Ollama model.

    Returns (clean_text, ttft_seconds, total_seconds). Streams over HTTP so we can
    time the first token; if the server isn't up, falls back to `ollama run`
    (which starts it) and reports ttft=None. <think> blocks are stripped so a
    thinking model can't leak reasoning into the output.
    """
    prompt = PROMPTS[mode].format(text=text)
    t0 = time.perf_counter()
    try:
        req = urllib.request.Request(
            f"{url}/api/generate",
            data=json.dumps({"model": model, "prompt": prompt, "stream": True}).encode(),
            headers={"Content-Type": "application/json"},
        )
        ttft, parts = None, []
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for line in r:
                if not line.strip():
                    continue
                chunk = json.loads(line)
                if (piece := chunk.get("response", "")):
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    parts.append(piece)
                if chunk.get("error"):
                    raise RuntimeError(chunk["error"])
                if chunk.get("done"):
                    break
        return _THINK.sub("", "".join(parts)).strip(), ttft, time.perf_counter() - t0
    except urllib.error.URLError:
        # ponytail: server not reachable; the CLI auto-starts it. No streaming, so no TTFT.
        res = subprocess.run(["ollama", "run", model, prompt], capture_output=True, text=True, timeout=timeout)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or "ollama run failed")
        return _THINK.sub("", res.stdout).strip(), None, time.perf_counter() - t0


if __name__ == "__main__":
    # ponytail: pure-logic checks only; live model calls are covered by `v2t bench`.
    assert set(STT) == {"parakeet", "whisper"}
    assert make_stt.__module__  # importable
    assert _THINK.sub("", "<think>nope</think>Hello.").strip() == "Hello."
    assert "filler" in PROMPTS["strict"] and "Keep the original phrasing" in PROMPTS["casual"]
    try:
        make_stt("bogus")
    except SystemExit:
        pass
    else:
        raise AssertionError("unknown backend must exit")
    print("backends.py: all checks passed")
