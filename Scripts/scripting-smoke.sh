#!/bin/zsh
# AppleScript surface smoke test. Relaunches the app (verified fresh via
# `build stamp`), then exercises every scriptable verb that does not need
# loaded models. Exits non-zero on the first failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/relaunch-scripting.sh"

PASS=0; FAIL=0
check() {  # check <label> <applescript>
  local label=$1 script=$2 out
  if out=$(timeout 30 osascript -e "tell application \"VoiceOverStudio\" to $script" 2>&1); then
    echo "  ok   $label${out:+ -> ${out:0:60}}"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label: $out"
    FAIL=$((FAIL+1))
  fi
}

echo "properties:"
check "build stamp"        'get build stamp'
check "status"             'get status'
check "busy"               'get busy'
check "speech ready"       'get speech ready'
check "compute tier"       'get compute tier'
check "export format"      'get export format'
check "voices"             'get id of every voice'

echo "narrations:"
check "create narration"   'create narration script "Smoke test one." speaker "documentary"'
check "read text"          'get text of narration 1'
check "set text"           'set text of narration 1 to "Smoke test edited."'
check "set voice"          'set voice of narration 1 to "narrator_warm"'
check "set speed"          'set speed of narration 1 to fast'
check "set gap"            'set gap of narration 1 to 0.75'
check "replicate"          'replicate narration 1'
check "relocate"           'relocate narration 1 destination 2'
check "discard"            'discard slot 2'

echo "jingles:"
check "create cue"         'create cue preset "news_sting"'
check "verify"             'verify jingle 1'

echo "app verbs:"
check "menu items"         'menu items'
check "perform action"     'perform action "stop playback"'
check "wait until idle"    'wait until idle timeout 5'
check "screenshot"         'capture screenshot'

T=$(mktemp -d)/t.json
echo "files:"
check "save transcript"    "save transcript to \"$T\""
check "load transcript"    "load transcript from \"$T\""

echo
echo "passed $PASS, failed $FAIL"
exit $((FAIL > 0))
