#!/bin/zsh
# Rebuild the app bundle and relaunch it for AppleScript testing.
# Kills any running instance first and confirms via `build stamp` that the
# process answering Apple Events is the one just launched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_ROOT/Build/debug/VoiceOverStudio.app"
BIN="$APP/Contents/MacOS/VoiceOverStudio"

"$SCRIPT_DIR/build-app-bundle.sh" debug >/dev/null

# Kill every instance, wherever it was launched from, and wait for exit.
pkill -f 'VoiceOverStudio.app/Contents/MacOS/VoiceOverStudio' 2>/dev/null || true
for _ in {1..50}; do
  pgrep -f 'VoiceOverStudio.app/Contents/MacOS/VoiceOverStudio' >/dev/null || break
  sleep 0.2
done

VOS_BACKGROUND_LAUNCH=1 "$BIN" >/dev/null 2>&1 &
APP_PID=$!

for _ in {1..60}; do
  STAMP=$(osascript -e 'tell application "VoiceOverStudio" to get build stamp' 2>/dev/null) || STAMP=""
  if [[ "$STAMP" == *"pid $APP_PID"* ]]; then
    echo "fresh instance confirmed: $STAMP"
    exit 0
  fi
  sleep 0.5
done

echo "ERROR: app did not come up as pid $APP_PID (stamp: ${STAMP:-none})" >&2
exit 1
