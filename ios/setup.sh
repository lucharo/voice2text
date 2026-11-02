#!/bin/bash
# Generate the Xcode project, and optionally build or test.
#   ./setup.sh          generate V2T.xcodeproj
#   ./setup.sh test     generate + run the unit tests on an iPhone simulator
# Env: V2T_TEAM (Apple development team for signing), V2T_SIM (simulator name or UDID; default: first iPhone).
set -euo pipefail
cd "$(dirname "$0")"
export V2T_TEAM=${V2T_TEAM:-7V3HZUL435}
xcodegen generate --quiet

if [ "${1:-}" = test ]; then
  sim=${V2T_SIM:-$(xcrun simctl list devices available | sed -nE 's/^ +iPhone[^(]*\(([0-9A-F-]{36})\).*/\1/p' | head -1)}
  [ -n "$sim" ] || { echo "no iPhone simulator available; create one in Xcode" >&2; exit 1; }
  xcodebuild -project V2T.xcodeproj -scheme V2T -destination "id=$sim" -derivedDataPath build -quiet test
fi
