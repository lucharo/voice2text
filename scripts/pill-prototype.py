"""Throwaway native UI comparison: build with `just pill-prototype OUTPUT_DIR`."""

import os
import sys
from pathlib import Path

from v2t import menubar

destination = Path(sys.argv[1]).expanduser().resolve()
destination.mkdir(parents=True, exist_ok=True)
os.environ["V2T_HOME"] = str(destination / "state")
menubar.BUNDLE_ID = "com.lucharo.voice2text.pr33test"
print(menubar.build(destination / "Voice2Text PR33 Test.app", bake_paths=True))
