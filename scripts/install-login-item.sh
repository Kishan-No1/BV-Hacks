#!/bin/bash
# Starts notchAgent at login and restarts it if it crashes (not after you quit it from the menu).
#
#   scripts/install-login-item.sh [--app PATH] [--uninstall]
#
# Writes ~/Library/LaunchAgents/dev.notchagent.app.plist pointing at the app's binary and loads it now.
# Run it again after moving the app. --uninstall unloads and removes the agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP="$SCRIPT_DIR/../build/notchAgent.app"
LABEL="dev.notchagent.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "install-login-item: unknown option $1" >&2; exit 2 ;;
  esac
done

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$PLIST"
  echo "Removed the notchAgent login item."
  exit 0
fi

APP="$(cd "$APP" && pwd -P)"
BIN="$APP/Contents/MacOS/notchAgent"
[ -x "$BIN" ] || { echo "install-login-item: $BIN not found; run scripts/bundle.sh first" >&2; exit 1; }

# A copy started by hand would make the login item's copy exit at once (one island only).
pkill -f "$BIN" 2>/dev/null || true
sleep 0.5

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Restart after a crash, not after a normal Quit. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/notchAgent.log</string>
</dict>
</plist>
EOF
plutil -lint -s "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "notchAgent now starts at login ($PLIST). Log: ~/Library/Logs/notchAgent.log"
