#!/bin/bash
# Copy the v2t keyboard debug log (#162) off an iPhone, or a Simulator, into ~/.v2t/eval/kb-logs/<device>-<time>/.
#
#   ios/tools/fetch_kb_log.sh                 # the one paired iPhone that is connected
#   ios/tools/fetch_kb_log.sh "iPhone L"      # a device by name, UDID or identifier (xcrun devicectl list devices)
#   ios/tools/fetch_kb_log.sh --sim <udid>    # a Simulator (booted or not)
#
# Then: uv run ios/tools/kb_log_report.py ~/.v2t/eval/kb-logs/<folder>
# The log lives in the App Group container (group.es.luischav.v2t) under KeyboardLog/: keyboard.jsonl and, once
# that passed 4 MB, keyboard.1.jsonl with the older events. devicectl reads the App Group of the installed build,
# TestFlight builds included (checked on build 3, 8 Nov 2026).
set -euo pipefail
group=group.es.luischav.v2t
stamp=$(date +%Y%m%d-%H%M%S)
root="$HOME/.v2t/eval/kb-logs"

if [ "${1:-}" = "--sim" ]; then
  udid=${2:?usage: fetch_kb_log.sh --sim <udid>}
  # get_app_container needs a booted Simulator; a shut-down one keeps its group containers on disk
  base="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Shared/AppGroup"
  src=$(grep -l "$group" "$base"/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs -I{} dirname {})
  [ -n "$src" ] && [ -d "$src/KeyboardLog" ] || { echo "no keyboard log in Simulator $udid" >&2; exit 1; }
  dest="$root/sim-$udid-$stamp"
  mkdir -p "$dest"
  cp "$src"/KeyboardLog/*.jsonl "$dest"/
else
  device=${1:-}
  if [ -z "$device" ]; then
    # the first connected physical device
    device=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$|^[0-9A-F-]{36}$/) {print $i; exit}}')
    [ -n "$device" ] || { echo "no connected iPhone: pass its name or UDID (xcrun devicectl list devices)" >&2; exit 1; }
  fi
  dest="$root/$(echo "$device" | tr -c 'A-Za-z0-9-' '_')-$stamp"
  mkdir -p "$dest"
  xcrun devicectl device copy from --device "$device" --domain-type appGroupDataContainer \
    --domain-identifier "$group" --source KeyboardLog --destination "$dest" --quiet
fi
echo "$dest"
ls -l "$dest"
