# Benchmarks

Which speech model makes the fewest mistakes, and how long you wait for it. Each dot is one model
on the maintainers' grid; lower and further left is better.

![Words wrong against the median wait after release, on 208 real dictations and 150 meeting clips. Parakeet v3 on Core ML, the default: 5.6% and 29.5% at 0.13 and 0.05 s. Qwen3-ASR: 2.9% and 28.4% at 0.85 and 0.30 s](images/models.svg)

| Backend | Real dictations | Meetings, room microphone | Phone calls | Wait, real dictations |
|---|--:|--:|--:|--:|
| `parakeet-coreml` (default) | 5.6% | 29.5% | 10.3% | 0.13 s |
| `qwen3-asr` | 2.9% | 28.4% | 8.6% | 0.85 s |
| `parakeet` (MLX) | 5.8% | 33.3% | 10.8% | 0.25 s |
| `parakeet`, Parakeet Unified EN | 5.1% | 33.2% | 8.3% | 0.48 s |

Words wrong, after Whisper's text normalisation, so punctuation and capitals do not count.

- **Real dictations**: 208 of the maintainer's own, from a few seconds to 12 minutes. They have no
  hand-made transcript, so each is scored against the one that Wispr Flow, Cohere Transcribe and
  Qwen3-ASR (full precision) agree with most, which flatters Qwen3-ASR a little; see
  [Should I switch to Qwen3-ASR?](faq.md#should-i-switch-to-qwen3-asr)
- **Meetings** and **phone calls**: 150 clips each from AMI (single distant microphone) and
  Earnings22, with human labels.
- Measured on an M4 Pro in October 2026. Recordings over a minute are decoded in pieces while you
  hold the key, as v2t does. The grid and its scripts are in
  [`utils/asr_grid`](https://github.com/lucharo/voice2text/tree/main/utils/asr_grid);
  `plot_models.py` draws this chart.
