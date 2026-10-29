"""The menu app's model pickers: which models v2t offers, and the state of each.

`v2t config --json` prints `pickers()` as its `models` section, so the Swift menu
draws the rows without knowing any model itself. The list is
`backends.STT_CHOICES` and `backends.CLEANUP_CHOICES`; this module adds, for this
Mac and this config, whether each is downloaded, whether it can be picked, whether
it is the one in use, and the `config set` pairs that switch to it.

Checks are file lookups only (no model import, no network), so the menu's call
stays near the 60 ms it took before.
"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
from urllib.parse import urlparse

from . import backends, config

# The module each extra brings, to tell whether it is installed.
_EXTRA_MODULES = {"whisper": "mlx_whisper", "qwen": "mlx_audio"}


def _extra_installed(extra: str) -> bool:
    return not extra or importlib.util.find_spec(_EXTRA_MODULES[extra]) is not None


def _default_model(backend: str) -> str:
    if backend in backends.STT:
        return backends.STT[backend].default_model
    return backends.CLEANUP[backend].default_model


def _ollama_pulled(tag: str) -> bool:
    """Whether Ollama holds `tag` (`name:tag` or `namespace/name:tag`), from its manifest file."""
    root = Path(os.environ.get("OLLAMA_MODELS") or Path.home() / ".ollama" / "models")
    name, _, version = tag.partition(":")
    if "/" not in name:
        name = f"library/{name}"
    return (root / "manifests" / "registry.ollama.ai" / name / (version or "latest")).is_file()


def _local_ollama(url: str) -> bool:
    return (urlparse(url).hostname or "") in ("localhost", "127.0.0.1", "::1")


def _downloaded(choice: backends.ModelChoice, cfg: config.Config) -> bool | None:
    """True or False for a model v2t loads; None for Off, or for an Ollama on
    another machine, whose models this Mac cannot see."""
    if choice.backend == "off":
        return None
    model = choice.model or _default_model(choice.backend)
    if choice.backend == "ollama":
        return _ollama_pulled(model) if _local_ollama(cfg.ollama_url) else None
    if choice.backend == "parakeet-coreml":
        from . import coreml

        return coreml.downloaded(choice.model)
    return backends.cached_locally(model)


def _size(gb: float) -> str:
    return f"{gb:.2g} GB"


def _row(choice: backends.ModelChoice, cfg: config.Config, current: bool, default: bool,
         settings: list[list[str]]) -> dict:
    downloaded = _downloaded(choice, cfg)
    available, note = True, ""
    if not _extra_installed(choice.extra):
        available, note = False, f"needs voice2text[{choice.extra}]"
    elif choice.backend == "ollama" and downloaded is None:
        note = f"on {urlparse(cfg.ollama_url).hostname}"
    elif choice.backend == "ollama" and not downloaded:
        available = False
        note = f"needs: ollama pull {choice.model or _default_model('ollama')}"
    elif downloaded:
        note = f"{_size(choice.size_gb)}, downloaded"
    elif downloaded is False:
        note = f"downloads {_size(choice.size_gb)} on first use"
    return {
        "id": choice.backend + (f":{choice.model}" if choice.model else ""),
        "label": choice.label + (" (default)" if default else ""),
        "size_gb": choice.size_gb,
        "downloaded": downloaded,
        "available": available,
        "current": current,
        "note": note,
        "set": settings,
    }


def _custom(model: str) -> dict:
    """A model set by hand in config.toml that no row offers: shown ticked, not pickable."""
    return {
        "id": "custom", "label": backends.short_model(model), "size_gb": None,
        "downloaded": None, "available": False, "current": True,
        "note": "set in config.toml", "set": [],
    }


def transcription(cfg: config.Config) -> list[dict]:
    default = config.Config()
    in_use = (cfg.backend, cfg.stt_model or _default_model(cfg.backend))
    rows = []
    for choice in backends.STT_CHOICES:
        if choice.backend not in backends.STT:
            continue
        rows.append(_row(
            choice, cfg,
            current=in_use == (choice.backend, choice.model or _default_model(choice.backend)),
            default=(choice.backend, choice.model) == (default.backend, default.stt_model),
            settings=[["transcription.backend", choice.backend], ["transcription.model", choice.model]],
        ))
    if not any(row["current"] for row in rows):
        rows.append(_custom(cfg.stt_model or cfg.backend))
    return rows


def cleanup(cfg: config.Config) -> list[dict]:
    default = config.Config()
    in_use = (
        ("off", "") if not cfg.cleanup_enabled
        else (cfg.cleanup_engine, cfg.cleanup_model or _default_model(cfg.cleanup_engine))
    )
    rows = []
    for choice in backends.CLEANUP_CHOICES:
        if choice.backend == "off":
            rows.append(_row(choice, cfg, current=in_use[0] == "off", default=False,
                             settings=[["cleanup.enabled", "false"]]))
            continue
        rows.append(_row(
            choice, cfg,
            current=in_use == (choice.backend, choice.model or _default_model(choice.backend)),
            default=(choice.backend, choice.model) == (default.cleanup_engine, default.cleanup_model),
            settings=[["cleanup.enabled", "true"], ["cleanup.engine", choice.backend],
                      ["cleanup.model", choice.model]],
        ))
    if not any(row["current"] for row in rows):
        rows.append(_custom(cfg.cleanup_model or cfg.cleanup_engine))
    return rows


def pickers(cfg: config.Config) -> dict:
    """The `models` section of `v2t config --json`."""
    return {"transcription": transcription(cfg), "cleanup": cleanup(cfg)}
