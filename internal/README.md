# Internal notes

Maintainer-only records. They stay in Git but are never built into the docs site (zensical only
reads `docs/`) or packed into the sdist (`pyproject.toml` lists what the sdist includes). Public
pages never link here.

| File | Holds |
|---|---|
| [releasing.md](releasing.md) | How each release went: CI publication, the PyPI outage, the local Mac fallback, signing |
| [streaming.md](streaming.md) | The measurements behind the 60 s rule and why the streamed text differs |
| [faq-evidence.md](faq-evidence.md) | The user FAQ's original entries, with code sources, measurements and verification dates |

## Benchmarks

Each keeps its own README with the command, inputs and how to read it. Per-clip results stay
private under `~/.v2t/eval` (or `~/.v2t/benchmarks`) and never enter the repository.

| Benchmark | Question | Inputs | Findings |
|---|---|---|---|
| [`benchmarks/`](../benchmarks/README.md) (`just bench`) | How fast is each speech and cleanup model on this Mac? | Clips generated with `say` | One file per Mac in `~/.v2t/benchmarks/results/` |
| [`utils/asr_grid`](../utils/asr_grid/README.md) | Which speech model, and should it stream or go in pieces? | LibriSpeech, FLEURS, 40 long labelled clips (`ls-long`), 208 real dictations | [Pieces vs stream](streaming.md#would-30-s-pieces-beat-the-5-s-stream-for-long-dictations); `~/.v2t/eval/grid/<date>-report.md` |
| [`utils/wisprflow_benchmarking_profiling`](../utils/wisprflow_benchmarking_profiling/README.md) | Is v2t faster and no worse than the dictation app it replaces? Which push size should streaming use? | 208 real dictations with audio | Its README; [streaming push size](streaming.md#why-is-the-streamed-text-not-identical-to-whole-file-decoding-when-it-is-the-same-model) |
| `utils/cleanup_speed` (docstring) | How fast can cleanup get without changing its output? | The dictations' raw transcripts | `~/.v2t/eval/cleanup-speed/<date>-report.md` |

Every one times the GPU, so run one at a time, check `df -h /` (≥ 15 GB) and `memory_pressure`
(free ≥ 40%; swap used is not a gate). On the work Mac, Defender holds load at 15-20, so time
variants interleaved clip by clip and record load per cell. Run anything longer than a few minutes
as a `launchctl submit` job: a child of the Claude app loses Metal when the app quits.

- **The grid's parakeet-mlx rows stay bf16.** The grid disables 0.5.15's 8-bit load. Compare
  against shipped speed with an interleaved A/B, not with grid waits.
- **Whole-file decoding needs much more memory as recordings get longer**
  ([#53](https://github.com/lucharo/voice2text/issues/53)): 3.8 GB at 160 s, 7.9 GB at 336 s, over
  30 GB at 738 s. The grid's parakeet-mlx runtime chunks clips over `WHOLE_FILE_MAX_S` (300 s)
  only for systems not in `hacky` mode: `parakeet-v3` and `parakeet-ultra` still decode every clip
  whole first, so rerunning them on long `wispr` clips can hit the same blow-up. Run every system,
  new or old, under a memory cap.
- **Core ML / ANE probes:** the FluidAudio CLI builds with the Command Line Tools, no Xcode needed.
  The first ANE load after the model files change recompiles (about 29 s), so report load
  separately. Keep probe scripts under `~/.v2t/eval/`, not `/tmp`.

### Are timings trustworthy while Defender loads the Mac?

Mostly, for the GPU part. Parakeet runs on the GPU and Defender's load is CPU: the 0.5.14 baseline
read 0.166 s on 2026-10-14 under load against 0.164 s in the 2026-10-06 benchmark. CPU work is the
weak spot. The old WAV-and-ffmpeg path went from 0.166 s to 0.195 s as load rose on the same day,
while the direct-decode arms held (#51). Absolute waits can still double on a busy Mac (the
2026-10-15 ANE rerun at load 16 to 60 read about 2× the quieter day), so compare arms that ran
interleaved in the same window and quote ratios rather than seconds. Before a rerun, gate on
5-minute load < 20 (Defender alone keeps 15-20, so a load < 10 gate can wait for hours),
`memory_pressure` free ≥ 40%, disk ≥ 15 GB and no other session's grid or model server running.

### Benchmarking on an iPhone

The iOS Simulator runs on the Mac's chip and has no Neural Engine, so it cannot stand in for a
phone. The chosen route is a small FluidAudio test app (an XCTest target is enough) built with
Xcode on the personal Mac and run on Luis's iPhone 16 Pro
([#52](https://github.com/lucharo/voice2text/issues/52)): about 50 grid clips, scored with the
grid's normalisation, warm runs timed after one compile run, phone plugged in with Low Power Mode
off and the thermal state logged. For more phones later, the same XCTest runs on rented devices:
BrowserStack App Automate (iPhone 16 Pro to 18 Pro) or AWS Device Farm (about $0.17 per
device-minute, 1,000 free minutes). The only numbers so far are an estimate from about 15 GFLOP
per second of audio (#52); Hugging Face is blocked on the GSK network, so model files come from
the personal Mac.

## Open verification gaps

- Live interaction with the pill selector was not exercised in the 5 October audit.
- Installation and a real dictation on the work Mac after the 0.5.3 release are separate checks.
- The launchd-without-bundle path has not been re-tested on macOS 26.
