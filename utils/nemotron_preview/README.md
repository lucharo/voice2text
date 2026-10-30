# Nemotron preview checks

Two scripts behind `transcription.preview = "nemotron"` (#19, `v2t/nemotron.py`).

- `parity.py` runs the Python port and FluidAudio's Swift (`fa-helper` from
  `utils/asr_grid`, PR #86) on the same clips and compares the final text and the sampled
  partial texts, token for token.
- `replay.py` replays recordings in real time through the app's own `process_live`, in a
  separate `V2T_HOME`, once with the backend's previews and once with Nemotron's,
  interleaved clip by clip. It records each change of the live text, Nemotron's cost per
  step, the wait after release, and whether the pasted text equals one direct decode of
  the recording. It never prints dictated text.

Run both under `taskpolicy -b nice -n 19` on a shared Mac, one at a time. Results of the
2026-10-29 run are in `internal/streaming.md`.
