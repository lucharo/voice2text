"""One reference/hypothesis pair scored the way the Open ASR Leaderboard scores it.

Mirrors open_asr_leaderboard at commit 2aaa07a5ea7c5b18ea53c511426d2079b35d1200:
- English: `EnglishTextNormalizer` (data_utils.normalizer).
- Other languages: `MultilingualNormalizer(remove_diacritics=False)` called with `lang=`, which
  also writes digits out as words with num2words (data_utils.ml_normalizer), then
  `normalize_compound_pairs` (eval_utils), as `nemo_asr/run_eval_ml.py` does.
- Alignment: kaldialign `edit_distance(..., merge_compounds=True)` (eval_utils._align_pair), so a
  compound split differently ("to night" against "tonight") costs nothing.
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher
from functools import lru_cache

from .normalizer import BasicMultilingualTextNormalizer, EnglishTextNormalizer


@lru_cache(maxsize=1)
def _english() -> EnglishTextNormalizer:
    return EnglishTextNormalizer()


@lru_cache(maxsize=1)
def _multilingual() -> BasicMultilingualTextNormalizer:
    return BasicMultilingualTextNormalizer(remove_diacritics=False)


def _numbers_to_words(text: str, lang: str) -> str:
    """data_utils.MultilingualNormalizer._normalize_numbers."""
    import num2words

    text = re.sub(r"(\d)\s+(\d{3})\b", r"\1\2", text)  # "10 000" -> "10000"

    def replace(m: re.Match) -> str:
        try:
            return num2words.num2words(int(m.group()), lang=lang)
        except Exception:
            return m.group()

    return re.sub(r"\d+", replace, text)


def normalise(text: str | None, lang: str) -> list[str]:
    """The leaderboard's normalised words for `text` in language `lang` ("en", "es", ...)."""
    if lang == "en":
        return _english()(text or "").split()
    return _numbers_to_words(_multilingual()(text or ""), lang).split()


def _compound_pairs(ref: list[str], hyp: list[str]) -> tuple[list[str], list[str]]:
    """eval_utils.normalize_compound_pairs for one pair: where a mismatched stretch has the same
    letters ignoring spaces, both sides take the joined form."""
    new_ref: list[str] = []
    new_hyp: list[str] = []
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, ref, hyp).get_opcodes():
        if tag != "equal" and "".join(ref[i1:i2]) == "".join(hyp[j1:j2]):
            new_ref.append("".join(ref[i1:i2]))
            new_hyp.append("".join(hyp[j1:j2]))
        else:
            new_ref.extend(ref[i1:i2])
            new_hyp.extend(hyp[j1:j2])
    return new_ref, new_hyp


def edits(ref: list[str], hyp: list[str], lang: str = "en") -> int:
    """Word errors (substitutions, deletions, insertions) between two normalised word lists."""
    from kaldialign import edit_distance

    if lang != "en":
        ref, hyp = _compound_pairs(ref, hyp)
    return edit_distance(tuple(ref), tuple(hyp), merge_compounds=True)["total"]


def score_pair(ref_text: str, hyp_text: str | None, lang: str) -> tuple[int, int]:
    """(errors, reference words) for one clip, as the leaderboard counts them."""
    ref = normalise(ref_text, lang)
    return edits(ref, normalise(hyp_text, lang), lang), len(ref)
