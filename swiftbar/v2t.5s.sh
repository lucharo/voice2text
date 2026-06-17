#!/bin/bash
#
# <bitbar.title>v2t</bitbar.title>
# <bitbar.version>0.3.0</bitbar.version>
# <bitbar.author>lucharo</bitbar.author>
# <bitbar.desc>Toggle and monitor voice2text from the menu bar.</bitbar.desc>
# <bitbar.dependencies>v2t</bitbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# Install: brew install swiftbar, then drop this file in your SwiftBar plugins
# folder (keep the `.5s.sh` suffix — a 5s safety refresh; v2t also pushes an
# instant repaint on every state change, so the icon tracks live activity).
#
# "Start v2t" from the menu needs SwiftBar to have Accessibility + Input
# Monitoring permissions (System Settings > Privacy). Without them, start v2t
# from a terminal and use the menu just for status / stop / opening folders.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
V2T_HOME="${V2T_HOME:-$HOME/.v2t}"

V2T_BIN="$(command -v v2t || true)"
for c in "$HOME/.local/bin/v2t" /opt/homebrew/bin/v2t /usr/local/bin/v2t; do
  [ -z "$V2T_BIN" ] && [ -x "$c" ] && V2T_BIN="$c"
done

# SwiftBar re-invokes this script with a param when a menu item is clicked.
case "$1" in
  start) mkdir -p "$V2T_HOME/run"; nohup "$V2T_BIN" >>"$V2T_HOME/run/v2t.log" 2>&1 & exit 0 ;;
  stop)  "$V2T_BIN" stop >/dev/null 2>&1; exit 0 ;;
esac

if [ -z "$V2T_BIN" ]; then
  echo "🎙️ ⚠️"
  echo "---"
  echo "v2t not found on PATH"
  echo "Install | href=https://github.com/lucharo/voice2text"
  exit 0
fi

# `v2t status` -> "off"  or  "<state>\t<model>\t<mode>"
STATUS="$("$V2T_BIN" status 2>/dev/null)"
STATE="$(printf '%s' "$STATUS" | cut -f1)"
MODEL="$(printf '%s' "$STATUS" | cut -f2)"
MODE="$(printf '%s' "$STATUS" | cut -f3)"

case "$STATE" in
  starting)     TITLE="🎙️🟠"; LINE="🟠 Starting… (loading models)" ; RUN=1 ;;
  idle)         TITLE="🎙️🟢"; LINE="🟢 Ready ($MODEL · $MODE)"     ; RUN=1 ;;
  recording)    TITLE="🎙️🔴"; LINE="🔴 Recording…"                 ; RUN=1 ;;
  transcribing) TITLE="🎙️🟡"; LINE="🟡 Transcribing…"              ; RUN=1 ;;
  cleaning)     TITLE="🎙️🟡"; LINE="🟡 Cleaning up…"               ; RUN=1 ;;
  *)            TITLE="🎙️";   LINE="○ Off"                         ; RUN=0 ;;
esac

echo "$TITLE"
echo "---"
echo "$LINE"
if [ "$RUN" = "1" ]; then
  echo "Stop v2t | bash=\"$0\" param0=stop terminal=false refresh=true"
else
  echo "Start v2t | bash=\"$0\" param0=start terminal=false refresh=true"
fi
echo "---"
echo "Open config (~/.v2t) | bash=/usr/bin/open param0=\"$V2T_HOME\" terminal=false"
echo "Open transcription history | bash=/usr/bin/open param0=\"$V2T_HOME/history\" terminal=false"
echo "Refresh | refresh=true"
