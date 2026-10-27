# Benchmarks

Which speech model makes the fewest mistakes, and how long it takes to decode a recording. Each
dot is one model on the maintainers' grid; lower and further left is better.

![Words wrong against the median wait after release, on 208 real dictations and 150 meeting clips on a room microphone. Parakeet v3 on Core ML, the default: 5.0% and 29.2% at 0.13 and 0.05 s. Qwen3-ASR: 2.4% and 28.2% at 0.85 and 0.30 s](images/models.svg)

| Backend | Real dictations | Meetings, room microphone | Meetings, headsets | Earnings calls | Decode after release |
|---|--:|--:|--:|--:|--:|
| `parakeet-coreml` (default) | 5.0% | 29.2% | 8.7% | 7.2% | 0.13 s |
| `qwen3-asr` | 2.4% | 28.2% | 7.7% | 5.9% | 0.85 s |
| `parakeet` (MLX, bf16 on the grid) | 5.4% | 33.3% | 8.9% | 6.1% | 0.25 s |
| `parakeet`, Parakeet Unified EN (bf16) | 4.9% | 32.7% | 7.8% | 6.7% | 0.48 s |

Words wrong, counted the way the [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)
counts them (its own code), so punctuation, capitals and compounds written apart do not count,
and the two right-hand sets are the leaderboard's own: these columns compare with the AMI and
Earnings22 numbers on model cards. Why the room microphone reads so much higher:
[FAQ](faq.md#why-do-v2ts-error-rates-differ-from-model-cards-and-the-open-asr-leaderboard).

- **Real dictations**: 208 of the maintainer's own, from a few seconds to 12 minutes. They have no
  hand-made transcript, so each is scored against the one that Wispr Flow, Cohere Transcribe and
  Qwen3-ASR (full precision) agree with most, which flatters Qwen3-ASR a little; see
  [Should I switch to Qwen3-ASR?](faq.md#should-i-switch-to-qwen3-asr)
- **Meetings, room microphone**: 150 clips of AMI on a single distant microphone, as a laptop
  hears a meeting, with human labels.
- **Meetings, headsets** and **earnings calls**: the leaderboard's AMI-Cleaned (150 clips, each
  speaker's headset) and Earnings22-Cleaned-AA (six calls, corrected transcripts). With six
  calls the earnings column is only good to 2 or 3 points either way.
- Measured on an M4 Pro in October 2026. The decode time is the grid's, median over the real
  dictations: the whole file under a minute, 30 s pieces decoded while you hold the key from a
  minute up. v2t itself cuts pieces sooner, so it waits less: 0.77 s for `qwen3-asr` measured
  through v2t's own backend. The grid runs MLX Parakeet at bf16; v2t loads it at 8 bits, about
  30% quicker with the same errors to within 0.1 point. The grid and its scripts are in
  [`utils/asr_grid`](https://github.com/lucharo/voice2text/tree/main/utils/asr_grid);
  `plot_models.py` draws this chart.
