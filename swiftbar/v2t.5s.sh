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
# v2t needs three permissions, granted to the app that LAUNCHES it (your terminal,
# or SwiftBar if you use "Start v2t"): Microphone (to record), Accessibility +
# Input Monitoring (to read the hotkey and paste). Use the Permissions submenu
# below, then RESTART that app — macOS only applies the grant on relaunch.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
V2T_HOME="${V2T_HOME:-$HOME/.v2t}"
mkdir -p "$V2T_HOME/run" "$V2T_HOME/history"   # so the Open… items always have a target
SEC="x-apple.systempreferences:com.apple.preference.security"

V2T_BIN="$(command -v v2t || true)"
for c in "$HOME/.local/bin/v2t" /opt/homebrew/bin/v2t /usr/local/bin/v2t; do
  [ -z "$V2T_BIN" ] && [ -x "$c" ] && V2T_BIN="$c"
done

# SwiftBar re-invokes this script with a param when a menu item is clicked.
case "$1" in
  start) nohup "$V2T_BIN" >>"$V2T_HOME/run/v2t.log" 2>&1 & exit 0 ;;
  stop)  "$V2T_BIN" stop >/dev/null 2>&1; exit 0 ;;
esac

if [ -z "$V2T_BIN" ]; then
  echo "🎙️ ⚠️"
  echo "---"
  echo "v2t not found on PATH"
  echo "Install | href=https://github.com/lucharo/voice2text"
  exit 0
fi

# `v2t status` -> "<state>\t<stt>\t<cleanup>\t<mode>"  (state is 'off' when not running)
STATUS="$("$V2T_BIN" status 2>/dev/null)"
STATE="$(printf '%s' "$STATUS" | cut -f1)"
STT="$(printf '%s' "$STATUS" | cut -f2)"
CLEANUP="$(printf '%s' "$STATUS" | cut -f3)"
MODE="$(printf '%s' "$STATUS" | cut -f4)"
[ "$CLEANUP" = "off" ] && CLEAN_LBL="no cleanup" || CLEAN_LBL="clean: $CLEANUP"

case "$STATE" in
  starting)     TITLE="🎙️🟠"; LINE="🟠 Starting… (loading models)" ; RUN=1 ;;
  idle)         TITLE="🎙️🟢"; LINE="🟢 Ready ($MODE)"              ; RUN=1 ;;
  recording)    TITLE="🎙️🔴"; LINE="🔴 Recording…"                 ; RUN=1 ;;
  transcribing) TITLE="🎙️🟡"; LINE="🟡 Transcribing…"              ; RUN=1 ;;
  cleaning)     TITLE="🎙️🟡"; LINE="🟡 Cleaning up…"               ; RUN=1 ;;
  *)            TITLE="🎙️";   LINE="○ Off"                         ; RUN=0 ;;
esac

echo "$TITLE"
echo "---"
echo "$LINE"
echo "$STT · $CLEAN_LBL | color=#8e8e93 size=12"
if [ "$RUN" = "1" ]; then
  echo "Stop v2t | bash=\"$0\" param0=stop terminal=false refresh=true"
else
  echo "Start v2t | bash=\"$0\" param0=start terminal=false refresh=true"
fi
echo "---"
echo "Permissions (grant, then restart the launching app)"
echo "--🎙️ Microphone | bash=/usr/bin/open param0=\"$SEC?Privacy_Microphone\" terminal=false"
echo "--♿ Accessibility | bash=/usr/bin/open param0=\"$SEC?Privacy_Accessibility\" terminal=false"
echo "--⌨️ Input Monitoring | bash=/usr/bin/open param0=\"$SEC?Privacy_ListenEvent\" terminal=false"
echo "Open config (~/.v2t) | bash=/usr/bin/open param0=\"$V2T_HOME\" terminal=false"
echo "Open transcription history | bash=/usr/bin/open param0=\"$V2T_HOME/history\" terminal=false"
echo "Refresh | refresh=true"
