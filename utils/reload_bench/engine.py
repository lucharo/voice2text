"""A v2t engine for the reload benchmark: `v2t run` with no keyboard listener.

Not user-facing and not packaged. The real listener would install a global event
tap, so a benchmark engine could swallow Esc or record on Fn in the apps in front;
this one replaces it with a listener that never hears a key. Everything else
(warmup, SIGHUP, SIGTERM, the status file) is the engine's own code, imported from
whichever v2t comes first on PYTHONPATH, so the same script times two checkouts.
A reload that re-executes the engine runs this script again.

    python utils/reload_bench/engine.py   # started by bench.py, which sets V2T_HOME
"""

from __future__ import annotations

import sys
import time

from v2t import app, cli


class _QuietListener:
    """Stands in for pynput's listener: alive until the engine stops, hears nothing."""

    def __init__(self, *_args, **_kwargs):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def is_alive(self) -> bool:
        return True

    def ensure_enabled(self) -> bool:
        return True


app._listener = _QuietListener
print(f"bench engine {time.time():.3f} v2t from {app.__file__}", flush=True)
sys.exit(cli.cmd_run([]))
