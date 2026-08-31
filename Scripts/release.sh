#!/bin/zsh
# Build, sign (Developer ID + hardened runtime), and zip a release of
# VoiceOverStudio. Notarization runs separately once credentials exist:
#   xcrun notarytool submit <zip> --keychain-profile <profile> --wait
#   xcrun stapler staple <app>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolve the Developer ID identity from the keychain unless SIGN_IDENTITY is set.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found; set SIGN_IDENTITY" >&2; exit 1; }
ENTITLEMENTS="$REPO_ROOT/Packaging/VoiceOverStudio.entitlements"
APP="$REPO_ROOT/Build/release/VoiceOverStudio.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$REPO_ROOT/Packaging/VoiceOverStudio-Info.plist")
ZIP="$REPO_ROOT/Build/VoiceOverStudio-$VERSION.zip"

echo "### Building release bundle (v$VERSION)..."
"$SCRIPT_DIR/build-app-bundle.sh" release >/dev/null

echo "### Signing with hardened runtime..."
# Static linkage means no nested frameworks; sign the bundle once, inside out
# is unnecessary. --deep is deprecated and unneeded here.
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

echo "### Verifying signature..."
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input && echo "entitlements: audio-input present"

echo "### Zipping..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "### Done: $ZIP"
