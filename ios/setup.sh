#!/bin/bash
# Generate the Xcode project, and optionally build or test.
#   ./setup.sh          generate V2T.xcodeproj
#   ./setup.sh test     generate + run the app's unit tests on an iPhone simulator
# The keyboard engines have their own Mac-run tests: (cd Packages/V2TKeyboardCore && swift test).
# Env: V2T_TEAM (Apple development team for signing), V2T_SIM (simulator name or UDID; default: first iPhone).
set -euo pipefail
cd "$(dirname "$0")"
export V2T_TEAM=${V2T_TEAM:-7V3HZUL435}
python3 tools/build_lexicons.py build/lexicons   # pinned AOSP word lists -> keyboard lexicons
# a synthetic dictation for the Simulator UI tests (V2T_FIXTURE_AUDIO), so no test records the room
if [ ! -f build/fixtures/dictation-en.wav ]; then
  mkdir -p build/fixtures
  say -o build/fixtures/dictation-en.aiff "Testing the v two t keyboard on the simulator."
  afconvert -f WAVE -d LEF32@16000 -c 1 build/fixtures/dictation-en.aiff build/fixtures/dictation-en.wav
fi
xcodegen generate --quiet

if [ "${1:-}" = test ]; then
  sim=${V2T_SIM:-$(xcrun simctl list devices available | sed -nE 's/^ +iPhone[^(]*\(([0-9A-F-]{36})\).*/\1/p' | head -1)}
  [ -n "$sim" ] || { echo "no iPhone simulator available; create one in Xcode" >&2; exit 1; }
  xcodebuild -project V2T.xcodeproj -scheme V2T -destination "id=$sim" -derivedDataPath build -quiet test
fi
