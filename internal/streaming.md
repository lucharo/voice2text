<!-- Maintainer-only. Never built into the docs site; public pages never link here. -->

# Streaming: evidence

The user-facing explanation is `docs/how-it-works.md`. These are the measurements and reasoning behind it, as recorded when the rule shipped.

## How do I turn streaming transcription on or off, and what does it actually change?

**Short answer:** It is on by default with the Parakeet backend: `streaming_mode = "hacky"` under
`[transcription]`, or `v2t --streaming-mode hacky`; `off` restores decoding after release. While the
hotkey is held the recogniser is fed every 5 s and the menu bar shows *Recording… N words*. Only
dictations of 60 s or more get faster: the wait after release drops from about 1.4 s median (4.7 s
p90, 111 s worst case on a 12-minute clip) to about 0.33 s, at the cost of slightly different text
(0.7% fewer words at the median, 5% at the 10th percentile). Under 60 s the recording is still
decoded whole-file on release, so the text and timing are unchanged. Cleanup latency is unchanged
either way. Whisper has no streaming path and always decodes after release.

### Sources

- [`STREAM_CHUNK_S`, `STREAM_TAKEOVER_S`](../v2t/backends.py) — the two constants and the
  measurements that picked them.
- [`process_live`](../v2t/app.py) — the feed loop and the 60 s takeover rule.
- [Streaming benchmark](../utils/wisprflow_benchmarking_profiling/README.md) — `--streaming`
  reports the latency left after release and the disagreement per duration bucket.

_Created: 2026-09-08 · Verified: 2026-09-08 (208 clips, M4 Pro, PR #17)._

## Why is the streamed text not identical to whole-file decoding, when it is the same model?

**Short answer:** Same weights, different attention. Parakeet's FastConformer encoder is
bidirectional: every audio frame attends to the whole clip, so offline decoding needs all the audio
first. parakeet-mlx's `transcribe_stream` swaps that for a ±20 s local window plus a cache, and
normalises the log-mel features per push, neither of which the offline checkpoint was trained for.
That is where the drift comes from, and why the mode is called `hacky`. Push size does not change
the latency (a push costs ~0.3 s whatever its length, because the context is re-encoded each time)
but it does change accuracy: on 208 clips 1 s pushes disagreed with whole-file decoding by 0.156 of
the words at the median, 5 s pushes by 0.062. A decoder-only model such as GPT-2 has none of this:
causal attention only looks left, so generating token by token is the batch computation split in
time. A `clean` mode would use a checkpoint trained to stream (NVIDIA's `parakeet-unified` or the
cache-aware Nemotron streaming models); none is in MLX yet. Whisper's encoder is also bidirectional
over a fixed 30 s window and mlx-whisper exposes no cached path, so streaming it would mean
re-encoding the last 30 s every second.

### Sources

- [`ParakeetStream`](../v2t/backends.py) — the wrapper around `transcribe_stream(context_size=(256, 256), depth=1)`.
- [Issue #19](https://github.com/lucharo/voice2text/issues/19) — the clean-mode candidates and the
  MLX gap.
- [Issue #12](https://github.com/lucharo/voice2text/issues/12) and
  [PR #17](https://github.com/lucharo/voice2text/pull/17) — the measurements behind the numbers.

_Created: 2026-09-08 · Verified: 2026-09-08._
