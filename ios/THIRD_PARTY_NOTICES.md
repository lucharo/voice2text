# Third-party notices for the iPhone app

## AOSP LatinIME word lists (Apache-2.0)

The keyboard's English and Spanish word lists are compiled at build time by `tools/build_lexicons.py` from
`dictionaries/en_US_wordlist.combined.gz` and `dictionaries/es_wordlist.combined.gz` in
https://android.googlesource.com/platform/packages/inputmethods/LatinIME at commit
127336e9f29d69607eab55982324b210279ae8c5. Copyright (c) 2008, The Android Open Source Project. Licensed under
the Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0

## Tatoeba sentences (CC BY 2.0 FR)

The keyboard's next-word statistics (which words most often follow which) are counted at build time by
`tools/build_lexicons.py` from the English and Spanish sentences of Tatoeba (https://tatoeba.org), as
re-wrapped in `en-es/train-00000-of-00001.parquet` of
https://huggingface.co/datasets/sentence-transformers/parallel-sentences-tatoeba at revision
cec1343ab5a7a8befe99af4a2d0ca847b6c84743. Tatoeba's sentences are by its contributors and licensed under
Creative Commons Attribution 2.0 France: https://creativecommons.org/licenses/by/2.0/fr/. Only word-pair counts
are kept; no sentence is shipped.

## FlorisBoard glide typing (Apache-2.0)

`Packages/V2TKeyboardCore/Sources/V2TKeyboardCore/SwipeDecoder.swift` follows the pruning (first and last key,
trace length within 8.42 key radii) and the shape and location standard deviations (22.08 per 200 samples,
0.5109 key radii) of `StatisticalGlideTypingClassifier.kt` in https://github.com/florisboard/florisboard at
commit fe1241f4921b3eae923571ff7a3e113a7e10d677. Copyright (C) 2025 The FlorisBoard Contributors. Licensed
under the Apache License, Version 2.0. The decoding approach is Kristensson and Zhai's SHARK2 (UIST 2004).
