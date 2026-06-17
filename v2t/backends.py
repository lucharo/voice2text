"""Speech-to-text backends and text-cleanup engines, both pluggable.

STT: parakeet (default) or whisper, both MLX. Cleanup: mlx (in-process via
mlx-lm, default — no daemon) or ollama. Heavy MLX imports are lazy so
`v2t config`/`v2t bench` work without a model loaded.
"""

from __future__ import annotations

import json
import time
import urllib.request

PARAKEET_DEFAULT = "mlx-community/parakeet-tdt-0.6b-v3"
WHISPER_DEFAULT = "mlx-community/whisper-large-v3-turbo"


class ParakeetSTT:
    default_model = PARAKEET_DEFAULT

    def __init__(self, model: str = ""):
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as e:
            raise SystemExit("parakeet-mlx missing — reinstall voice2text (Apple Silicon only).") from e
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

MLX_CLEANUP_DEFAULT = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
OLLAMA_CLEANUP_DEFAULT = "qwen3:4b-instruct-2507"


class MLXCleanup:
    """In-process cleanup via mlx-lm — no daemon, no HTTP. The default. Pick a
    non-thinking instruct model (the default Qwen3-Instruct-2507 doesn't think)."""

    default_model = MLX_CLEANUP_DEFAULT

    def __init__(self, model: str = "", url: str = ""):
        try:
            from mlx_lm import load, stream_generate
        except ImportError as e:
            raise SystemExit("mlx-lm missing — reinstall voice2text (Apple Silicon only).") from e
        self._stream = stream_generate
        self.model_id = model or self.default_model
        self.model, self.tokenizer = load(self.model_id)

    def cleanup(self, text: str, mode: str = "strict"):
        messages = [{"role": "user", "content": PROMPTS[mode].format(text=text)}]
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        t0, ttft, parts = time.perf_counter(), None, []
        for resp in self._stream(self.model, self.tokenizer, prompt, max_tokens=400):
            if ttft is None:
                ttft = time.perf_counter() - t0
            parts.append(resp.text)
        return "".join(parts).strip(), ttft, time.perf_counter() - t0


class OllamaCleanup:
    """Cleanup via a running Ollama server — for people who already use it."""

    default_model = OLLAMA_CLEANUP_DEFAULT

    def __init__(self, model: str = "", url: str = "http://localhost:11434"):
        self.model_id = model or self.default_model
        self.url = url

    def cleanup(self, text: str, mode: str = "strict", timeout: int = 60):
        prompt = PROMPTS[mode].format(text=text)
        req = urllib.request.Request(
            f"{self.url}/api/generate",
            data=json.dumps({"model": self.model_id, "prompt": prompt, "stream": True}).encode(),
            headers={"Content-Type": "application/json"},
        )
        t0, ttft, parts = time.perf_counter(), None, []
        with urllib.request.urlopen(req, timeout=timeout) as r:  # needs a running ollama server
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
        return "".join(parts).strip(), ttft, time.perf_counter() - t0


CLEANUP = {"mlx": MLXCleanup, "ollama": OllamaCleanup}


def make_cleanup(engine: str, model: str = "", url: str = "http://localhost:11434"):
    if engine not in CLEANUP:
        raise SystemExit(f"unknown cleanup engine {engine!r}; choose: {', '.join(CLEANUP)}")
    return CLEANUP[engine](model, url)


_LABELS = {
    "parakeet-tdt-0.6b-v3": "parakeet-v3",
    "parakeet-tdt-0.6b-v2": "parakeet-v2",
    "whisper-large-v3-turbo": "whisper-turbo",
    "Qwen3-4B-Instruct-2507-4bit": "Qwen3-4B",
    "Qwen2.5-3B-Instruct-4bit": "Qwen2.5-3B",
    "qwen3:4b-instruct-2507": "qwen3:4b",
}


def short_model(name: str) -> str:
    """Friendly menu-bar label, e.g. mlx-community/parakeet-tdt-0.6b-v3 -> parakeet-v3."""
    tail = name.rsplit("/", 1)[-1]
    return _LABELS.get(tail, tail)


if __name__ == "__main__":
    # ponytail: pure-logic checks only; live model calls are covered by `v2t bench`.
    assert set(STT) == {"parakeet", "whisper"}
    assert set(CLEANUP) == {"mlx", "ollama"}
    assert short_model("mlx-community/parakeet-tdt-0.6b-v3") == "parakeet-v3"
    assert short_model("mlx-community/Qwen3-4B-Instruct-2507-4bit") == "Qwen3-4B"
    assert short_model("custom/unknown") == "unknown"
    assert "filler" in PROMPTS["strict"] and "Keep the original phrasing" in PROMPTS["casual"]
    for fn in (make_stt, make_cleanup):
        try:
            fn("bogus")
        except SystemExit:
            pass
        else:
            raise AssertionError(f"{fn.__name__} must exit on unknown name")
    print("backends.py: all checks passed")
