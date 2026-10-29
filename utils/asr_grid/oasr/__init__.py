"""The Open ASR Leaderboard's word-error scoring, so the grid's numbers compare with its.

`normalizer.py` and `english_abbreviations.py` are copied unchanged from
https://github.com/huggingface/open_asr_leaderboard/tree/2aaa07a5ea7c5b18ea53c511426d2079b35d1200/normalizer
(Apache-2.0, see NOTICE). `score.py` reproduces how that repository scores one pair of texts:
its `normalizer/data_utils.py` (MultilingualNormalizer) and `normalizer/eval_utils.py`
(`normalize_compound_pairs`, `_align_pair`) at the same commit.
"""

from .score import normalise, edits, score_pair

__all__ = ["normalise", "edits", "score_pair"]
