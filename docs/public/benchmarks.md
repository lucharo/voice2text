# Benchmarks

Compare the recorded Mac and iPhone measurements. Transcription, cleanup and word preservation
are separate tests.

<div class="v2t-bench" data-v2t-bench data-source="../assets/benchmarks.json" markdown="0"><p class="bench-loading" role="status">Loading recorded measurements…</p></div>

<noscript><p><a href="../assets/benchmarks.json">Download the recorded benchmark data (JSON).</a></p></noscript>

## Marimo notebook

The [STT model intake notebook](https://github.com/lucharo/voice2text/blob/main/utils/model_intake/intake.py)
compares Mac speech models and engines by accuracy, wait and size. It reads local grid results;
a [working browser embed is tracked in #121](https://github.com/lucharo/voice2text/issues/121).

## Devices tested { #on-the-iphone }

All phone benchmarks ran on an iPhone 16 Pro, in a separate benchmark app. The iOS app was also tried on an iPhone 17 Pro. See [iPhone and iPad](iphone.md) for setup and device limits. These measurements do not establish performance on other devices or newer app builds.

## Keyboard correctness

Unit and Simulator tests cover typing rules, the dictionary and Swift/Python cleanup-guard parity.
Synthetic swipe traces test decoder quality. Real-finger accuracy, iPad device behaviour and phone
keystroke latency have not been benchmarked.

??? note "Methods and sources"

    - [Mac and iPhone speech results](https://github.com/lucharo/voice2text/issues/85#issuecomment-6485101617): human-labelled clips, scored with the Open ASR Leaderboard's normalisation. Mac datasets stay separate. The iPhone comparison uses the same 450 clips for both offline int8 models.
    - [Cleanup fidelity](https://github.com/lucharo/voice2text/issues/67#issuecomment-6444626974): 600 Parakeet transcripts, 150 each from LibriSpeech clean, other, AMI-SDM and Earnings22. Whisper-normalized WER counts word errors; formatted Earnings22 also counts case and punctuation. Apple's dictation-framed model is shown before and after the word guard.
    - [Cleanup pipeline timing](https://github.com/lucharo/voice2text/issues/67#issuecomment-6485264663): the completed 600-pair Qwen2.5-0.5B comparison, superseding the earlier partial runs. Core ML LUT6 and MLX 4-bit use different weight formats.
    - [Other cleanup models tested](https://github.com/lucharo/voice2text/issues/67#issuecomment-6449535063): exploratory trials, whose latencies are not ranked together here.

    These charts reproduce published October 2026 tables. The
    [benchmark harness and resource hashes](https://github.com/lucharo/voice2text/tree/main/utils/phone_bench)
    are committed, but the input bundle and per-clip outputs are not. Those raw files were unavailable
    during this docs rebuild, so the scores have not been independently recomputed. One phone's results
    do not establish performance on other devices.

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-06 · commit `2b4ec6f` · verified against code._
