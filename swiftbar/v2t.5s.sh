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
# folder (keep the `.5s.sh` suffix — SwiftBar refreshes the live state every 5s).
#
# v2t needs three permissions, granted to the app that LAUNCHES it (your terminal,
# or SwiftBar if you use "Start v2t"): Microphone (to record), Accessibility +
# Input Monitoring (to read the hotkey and paste). Use the Permissions submenu
# below, then RESTART that app — macOS only applies the grant on relaunch.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
umask 077
if [ -z "${V2T_HOME:-}" ]; then
  V2T_HOME="${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/v2t}"
  V2T_HOME="${V2T_HOME:-$HOME/.v2t}"
fi
export V2T_HOME
mkdir -p "$V2T_HOME/run" "$V2T_HOME/history"
chmod 700 "$V2T_HOME" "$V2T_HOME/run" "$V2T_HOME/history"
SEC="x-apple.systempreferences:com.apple.preference.security"
SERVICE_PLIST="$HOME/Library/LaunchAgents/com.lucharo.voice2text.plist"

V2T_BIN="$(command -v v2t || true)"
for c in "$HOME/.local/bin/v2t" /opt/homebrew/bin/v2t /usr/local/bin/v2t; do
  [ -z "$V2T_BIN" ] && [ -x "$c" ] && V2T_BIN="$c"
done

if [ -z "$V2T_BIN" ]; then
  echo "🎙️ ⚠️"
  echo "---"
  echo "v2t not found on PATH"
  echo "Install | href=https://github.com/lucharo/voice2text"
  exit 0
fi

# SwiftBar re-invokes this script with a param when a menu item is clicked.
case "$1" in
  start)
    LOG="$V2T_HOME/run/v2t.log"
    [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 1048576 ] && mv -f "$LOG" "$LOG.1"
    touch "$LOG"; chmod 600 "$LOG"
    if [ -f "$SERVICE_PLIST" ]; then
      "$V2T_BIN" service start >>"$LOG" 2>&1
    else
      nohup "$V2T_BIN" >>"$LOG" 2>&1 &
    fi
    exit 0
    ;;
  stop)
    "$V2T_BIN" stop >/dev/null 2>&1
    exit 0
    ;;
esac

# `v2t status` -> state, models, mode, error, then the three permission states.
if ! STATUS="$("$V2T_BIN" status 2>/dev/null)"; then
  STATUS="$(printf 'config-error\t?\t?\t?\tv2t status failed — check config or log\tunknown\tunknown\tunknown')"
fi
STATE="$(printf '%s' "$STATUS" | cut -f1)"
STT="$(printf '%s' "$STATUS" | cut -f2)"
CLEANUP="$(printf '%s' "$STATUS" | cut -f3)"
MODE="$(printf '%s' "$STATUS" | cut -f4)"
ERROR="$(printf '%s' "$STATUS" | cut -f5)"
MIC_PERMISSION="$(printf '%s' "$STATUS" | cut -f6)"
AX_PERMISSION="$(printf '%s' "$STATUS" | cut -f7)"
INPUT_PERMISSION="$(printf '%s' "$STATUS" | cut -f8)"
[ "$CLEANUP" = "off" ] && CLEAN_LBL="no cleanup" || CLEAN_LBL="clean: $CLEANUP"
[ "$CLEANUP" = "off" ] && START_STEPS=1 || START_STEPS=2

permission_item() {
  NAME="$1"; STATE="$2"; PANE="$3"
  case "$STATE" in
    granted)       ICON="✓"; LABEL="Granted" ;;
    not-requested) ICON="○"; LABEL="Start v2t to request" ;;
    denied)        ICON="✕"; LABEL="Denied" ;;
    restricted)    ICON="✕"; LABEL="Restricted" ;;
    missing)       ICON="○"; LABEL="Not granted" ;;
    *)             ICON="?"; LABEL="Unknown" ;;
  esac
  echo "$ICON $NAME · $LABEL | bash=/usr/bin/open param0=\"$SEC?$PANE\" terminal=false"
}

case "$STATE" in
  loading-stt)  TITLE="🎙️🟠"; LINE="🟠 Starting 1/$START_STEPS · Loading $STT…" ; RUN=1 ;;
  loading-cleanup) TITLE="🎙️🟠"; LINE="🟠 Starting 2/2 · Loading $CLEANUP…" ; RUN=1 ;;
  idle)         TITLE="🎙️🟢"; LINE="🟢 Ready ($MODE)"              ; RUN=1 ;;
  recording)    TITLE="🎙️🔴"; LINE="🔴 Recording…"                 ; RUN=1 ;;
  transcribing) TITLE="🎙️🟡"; LINE="🟡 Transcribing…"              ; RUN=1 ;;
  cleaning)     TITLE="🎙️🟡"; LINE="🟡 Cleaning up…"               ; RUN=1 ;;
  stopping)     TITLE="🎙️🟠"; LINE="🟠 Finishing current transcription…" ; RUN=1 ;;
  error)        TITLE="🎙️⚠️"; LINE="⚠️ $ERROR"                     ; RUN=1 ;;
  launch-error) TITLE="🎙️⚠️"; LINE="⚠️ $ERROR"                     ; RUN=0 ;;
  config-error) TITLE="🎙️⚠️"; LINE="⚠️ $ERROR"                     ; RUN=0 ;;
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
[ -f "$SERVICE_PLIST" ] && echo "Start at login: on | color=#8e8e93 size=12" || echo "Start at login: off | color=#8e8e93 size=12"
echo "---"
echo "Permissions"
permission_item "🎙️ Microphone" "$MIC_PERMISSION" "Privacy_Microphone"
permission_item "♿ Accessibility" "$AX_PERMISSION" "Privacy_Accessibility"
permission_item "⌨️ Input Monitoring" "$INPUT_PERMISSION" "Privacy_ListenEvent"
echo "---"
echo "Config | bash=/usr/bin/open param0=\"$V2T_HOME\" terminal=false"
echo "Transcription History | bash=/usr/bin/open param0=\"$V2T_HOME/history\" terminal=false"
[ -f "$V2T_HOME/run/v2t.log" ] && echo "Log | bash=/usr/bin/open param0=\"$V2T_HOME/run/v2t.log\" terminal=false"
echo "Refresh | refresh=true"
