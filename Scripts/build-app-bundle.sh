#!/bin/zsh
set -euo pipefail

APP_NAME="VoiceOverStudio"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
OUTPUT_ROOT="$REPO_ROOT/Build/$CONFIGURATION"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST_SOURCE="$REPO_ROOT/Packaging/VoiceOverStudio-Info.plist"

if [[ ! -f "$INFO_PLIST_SOURCE" ]]; then
  echo "Missing Info.plist template at $INFO_PLIST_SOURCE" >&2
  exit 1
fi

pushd "$REPO_ROOT" >/dev/null
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIGURATION" --product "$APP_NAME" --show-bin-path)"
popd >/dev/null

EXECUTABLE="$BIN_PATH/$APP_NAME"
RESOURCE_BUNDLE="$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Built executable not found at $EXECUTABLE" >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "SwiftPM resource bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"

cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/${APP_NAME}_${APP_NAME}.bundle"
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/${APP_NAME}_${APP_NAME}.bundle"

if [[ -f "$BIN_PATH/default.metallib" ]]; then
  cp "$BIN_PATH/default.metallib" "$RESOURCES_DIR/default.metallib"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "$APP_BUNDLE"
