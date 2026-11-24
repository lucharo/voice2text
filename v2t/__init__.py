"""v2t — local, MLX-first voice-to-text with LLM cleanup."""

import time as _time

__version__ = "0.6.2"

# When Python began loading v2t, for the start-up timings in v2t.log (#207). The time
# before this (the interpreter itself) shows as the gap after the menu app's
# "started the engine" line.
LOADING_STARTED = _time.perf_counter()
