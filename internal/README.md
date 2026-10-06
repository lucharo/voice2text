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

Every one times the GPU, so run one at a time, check `df -h /` and swap first, and run anything
longer than a few minutes as a `launchctl submit` job: a child of the Claude app loses Metal when
the app quits.

## Open verification gaps

- Live interaction with the pill selector was not exercised in the 5 October audit.
- Installation and a real dictation on the work Mac after the 0.5.3 release are separate checks.
- The launchd-without-bundle path has not been re-tested on macOS 26.
