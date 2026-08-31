#!/bin/zsh
# Capture the VoiceOverStudio window via the window server (screencapture -l).
# Needs Screen Recording permission for the invoking terminal, which the in-app
# `capture screenshot` verb cannot use; this is the full-fidelity path.
# Usage: capture-window.sh <output.png>
set -euo pipefail
OUT="${1:?usage: capture-window.sh <output.png>}"
WID=$(swift - <<'SWIFT' 2>/dev/null
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    if let owner = w[kCGWindowOwnerName as String] as? String, owner == "VoiceOverStudio",
       let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
       let id = w[kCGWindowNumber as String] as? Int {
        print(id); break
    }
}
SWIFT
)
[[ -n "$WID" ]] || { echo "No VoiceOverStudio window on screen" >&2; exit 1; }
screencapture -x -o -l "$WID" "$OUT"
echo "$OUT"
