# Scripting VoiceOverStudio with AppleScript

The app bundle exposes its full surface over Apple Events, so an agent (or
plain `osascript`) can drive every workflow headlessly: build a script, polish
it with the local LLM, synthesize speech, and export the finished track.

Build and launch a scriptable instance:

```bash
./Scripts/relaunch-scripting.sh   # rebuilds, kills stale instances, verifies freshness
./Scripts/scripting-smoke.sh      # runs the 24-check surface test
```

`VOS_BACKGROUND_LAUNCH=1` (or `--background`) launches without stealing focus.

## Quick tour

```applescript
tell application "VoiceOverStudio"
    initialize engines                    -- blocks until models are loaded
    set p to create narration script "The signal arrived at 3 PM." speaker "documentary"
    polish narration p                    -- LLM rewrite for TTS (blocks)
    set speed of narration p to fast
    synthesize narration p                -- returns the WAV path (blocks)
    export sequence to "/tmp/track.m4a"   -- stitched export, no save panel
    capture screenshot to "/tmp/app.png"  -- app-rendered PNG, no permissions needed
end tell
```

## Surface

**Application properties** — `status`, `busy`, `speech ready`, `language model
ready`, `compute tier` (small/medium/high), `speech model repository`,
`language model path`, `default gap`, `export format` (M4A/WAV), `reference
voice enrolled`, `setup progress`, `setup narrative`, `build stamp`.

**Elements** — `narration N` (text, voice, speed, pitch, gap, output name,
audio path, generated, generating, position, id), `voice N` (id, name,
prompt), `jingle N` (name, role, abc source, target duration, speech safety).

**Application verbs** — `initialize engines`, `auto setup`, `create narration
script … speaker …`, `create cue preset …`, `generate all`, `stop playback`,
`export sequence to …`, `save transcript to …`, `load transcript from …`,
`capture screenshot [to …]`, `discard slot N`, `menu items`, `perform action
…`, `wait until idle [timeout N]`.

**Element verbs** (object-first dispatch) — `synthesize narration N`, `polish
narration N`, `rephrase narration N`, `preview narration N`, `replicate
narration N`, `relocate narration N destination M`, `verify jingle N`,
`render midi jingle N to …`, `preview jingle N`.

**Menu surface** — `menu items` lists every named UI action; `perform action
"…"` invokes one. Actions marked in `MenuSurface.swift` as presenting dialogs
(save/load/export via panels) block on a human; scripts should use the
path-taking verbs instead.

Long-running verbs suspend the Apple Event and resume it when the work
finishes, so scripts observe real completion, not fire-and-forget.

## Known quirks

- `count narrations` returns 0: NSCountCommand does not resolve this app's
  element storage. Count with `count of (get every narration)` instead.
- `delete narration N` fails for the same reason; use `discard slot N`.
- Screenshots render the app's own view hierarchy (no Screen Recording
  permission), but layer-backed SwiftUI may paint incompletely while the
  window is fully occluded or minimized.

## Terminology lessons encoded in the sdef

Hard-won rules for anyone extending the dictionary — violating any of these
produces silent dispatch failures or client-side misparses:

1. A verb must not end in a class noun (`add paragraph` parses as verb+noun),
   must not begin with a reserved word (`add`, `at`, `get`, `set`, `move`,
   `copy`, `make`), and parameter names must avoid reserved words (`at`).
2. `paragraph` is AppleScript's own text class; using it as an app class name
   makes `count paragraphs` count text client-side. Hence `narration`.
3. Element-targeted commands dispatch object-first: the receiving class needs
   `<responds-to>` with a real `<cocoa method>` implemented on the element
   class. There is no fallback to the command's `<cocoa class>`.
4. Application-level element storage belongs on the app delegate behind
   `application(_:delegateHandlesKey:)`.
5. `NSScriptSuiteRegistry` parses the sdef strictly and drops rejected
   definitions silently (complaints go to the unified log, not stderr).
6. When testing, verify the responding process identity via `build stamp` —
   `open` on an already-running app reuses the stale instance, and a quit that
   fails silently means every subsequent test hits old code.
