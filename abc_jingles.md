# ABC Jingles Port Plan

## Objective

Port the Zig ABC stack from the local workspace reference copy at `/Volumes/xb/voiceover/reference/abc` into native Swift inside VoiceOverStudio, preserving behavioral parity with the Zig implementation and exposing it as an in-app ABC jingle pipeline for reusable jingle cards.

The end state is:

- VoiceOverStudio can parse ABC text with parity against the Zig source.
- The app can turn parsed ABC into timed note/chord/bar/tempo events with multi-voice support.
- The app can play jingles in-process and optionally export MIDI for debugging and regression checks.
- The UI can store small ABC snippets as jingle cards and attach them to voice-over workflows.

## What Exists Today

### Zig source of truth

The Zig implementation already has the major pieces we need under `/Volumes/xb/voiceover/reference/abc`:

- `types.zig`: typed tune model, voices, fractions, features.
- `parser.zig`: top-level parser state, header/body handling, repeat expansion, line parsing, voice switching.
- `music_parser.zig`: note/chord/rest/bar parsing, tuplets, ties, broken rhythm, inline fields, bar accidentals.
- `voice_manager.zig`: named/numeric voice mapping and per-voice timeline restoration.
- `repeat.zig`: header-aware repeat expansion.
- `midi.zig`: MIDI event generation, tempo/key/time meta events, channel assignment, voice tracks.
- `writer.zig`: MIDI file serialization.
- `parser_test.zig` and `midi_timing_test.zig`: parity oracle for parser and timing behavior.

### Imported player reference

There is also an imported product-level reference doc at `/Volumes/xb/voiceover/reference/ABCplayer.md` copied from the external game project.

That document is useful for understanding the original playback assumptions and authoring workflow, but it was written for arcade and game-state usage, not spoken-word production.

Use it as:

- a baseline for what the original player considered reliable
- a reference for short-cue composition patterns
- a reminder that the original system optimized for deterministic gameplay music, not editorial voice-over timing

Do not treat it as a final product spec for VoiceOverStudio.

Companion review notes for the new app live in `/Volumes/xb/voiceover/VoiceOverStudio/abc_player_voiceover_review.md`.

### Current Swift state in VoiceOverStudio

The repo already has a partial ABC surface:

- `Sources/VoiceOverStudio/Services/ABC/ABCTypes.swift`
- `Sources/VoiceOverStudio/Services/ABC/ABCParser.swift`
- `Sources/VoiceOverStudio/Services/ABC/ABCRepeatExpander.swift`
- `Tests/VoiceOverStudioTests/ABCParityTests.swift`

This is only a scaffold today. It validates repeat expansion and `K:` presence, but it does not yet implement the Zig parser, per-voice timeline management, timed feature extraction, MIDI generation, or playback.

## Porting Principle

Do not redesign the parser first. Port the Zig behavior as literally as practical into Swift, prove parity with tests, then add a thin Swift-native playback and app integration layer on top.

That keeps risk low because the hard part is not Swift syntax. The hard part is preserving the exact timing, feature emission order, voice semantics, accidentals, and repeat behavior that the Zig code already encodes.

## Target Swift Architecture

Keep the existing `Services/ABC` area and grow it into a complete subsystem.

Suggested files:

- `ABCTypes.swift`
  - Expand existing model to full Zig parity.
- `ABCParser.swift`
  - Keep as orchestration layer only.
- `ABCMusicParser.swift`
  - Port from `music_parser.zig`.
- `ABCVoiceManager.swift`
  - Port from `voice_manager.zig`.
- `ABCRepeatExpander.swift`
  - Keep, but validate line-for-line behavior against Zig.
- `ABCMIDIGenerator.swift`
  - Port from `midi.zig`.
- `ABCMIDIWriter.swift`
  - Port from `writer.zig`.
- `ABCJinglePlayer.swift`
  - Swift-native playback facade for the app.
- `ABCJingleCard.swift`
  - Data model for saved jingle cards.
- `ABCJingleService.swift`
  - App-facing service: parse, validate, preview, render, export, cache.

## Module Mapping

### 1. Core data model parity

Expand `ABCTypes.swift` until it is structurally equivalent to Zig:

- Add missing fraction helpers from Zig: integer multiply/divide helpers and any normalization utilities we need.
- Preserve feature richness: note, rest, chord, guitar chord, bar, tempo, time, key, voice.
- Keep `timestamp`, `voiceID`, and `lineNumber` on every emitted feature.
- Preserve voice defaults: key, timesig, unit length, transpose, octave shift, instrument, channel, velocity, percussion.

Important rule: the Swift types should be shaped for parity first, convenience second.

### 2. Top-level parser parity

`ABCParser.swift` should become a near-direct port of `parser.zig`:

- Parse state: `header`, `body`, `complete`.
- Reset behavior between parses.
- Run repeat expansion before tokenization.
- Handle comments, `%%MIDI`, `+:` continuation lines, standalone `[V:...]`, `V:` definitions, and voice switches.
- Emit warnings/errors similar to Zig where useful.
- Auto-create a default voice when needed.

Keep orchestration here only. Move note-level parsing out into `ABCMusicParser.swift`.

### 3. Voice manager parity

Port `voice_manager.zig` into `ABCVoiceManager.swift`:

- Track current voice.
- Support numeric and named voices.
- Support quoted multi-word voice names.
- Preserve per-voice timeline restoration when switching voices.
- Preserve default inheritance from the tune.
- Preserve explicit channel/instrument/percussion metadata for later playback/rendering.

This is critical for jingle cards because even short jingles may use melody/bass or percussion splits.

### 4. Music parser parity

Port `music_parser.zig` into `ABCMusicParser.swift` as the largest work item.

Required parity scope:

- Inline fields: `Q:`, `M:`, `L:`, `K:` in body.
- Notes and rests.
- Chords `[CEG]`.
- Guitar chord symbols `"C"`.
- Bar lines and accidental reset by bar.
- Grace-note skipping behavior.
- Tuplets.
- Broken rhythm `>` and `<`.
- Ties, including tie across barlines.
- Per-voice bar accidental memory.
- Inline `[V:name]` switches.
- Recovery behavior for malformed chords so later content still parses.

The goal is not “parse most songs”. The goal is “if Zig accepts and emits features for a tune, Swift emits the same semantic result”.

### 5. MIDI generation parity

Port `midi.zig` into `ABCMIDIGenerator.swift`:

- Generate note tracks per voice.
- Generate tempo track separately.
- Preserve channel allocation rules, including explicit channels and percussion handling.
- Emit program changes and controller events where Zig does.
- Emit note-on/note-off timing from whole-note timestamps exactly.
- Emit end-of-track at the full musical timeline, including trailing rests.
- Preserve optional guitar-chord playback behavior behind a Swift config flag.

Even if the app’s main player does not use MIDI files at runtime, the MIDI generator is still worth porting because it gives us:

- a parity checkpoint
- a debugging/export surface
- a simple interchange format for tests and future tooling

### 6. MIDI writer parity

Port `writer.zig` into `ABCMIDIWriter.swift`:

- Format 1 multi-track MIDI output.
- Variable-length delta writing.
- Stable event sorting by timestamp.
- Correct meta event serialization for tempo, time signature, key signature, text, and end-of-track.

This is not the user-facing feature. It is a verification and tooling layer.

## Playback Strategy For VoiceOverStudio

For in-app jingle playback, do not make the UI depend on temporary MIDI files unless needed. Use a Swift facade that can support both a direct player and a MIDI fallback.

The imported game-player document is a good starting point for deterministic cue handling, but VoiceOverStudio should optimize for spoken-word editorial workflows:

- precise intro and outro durations
- speech-safe instrument and percussion defaults
- stronger validation for cues that are technically parseable but editorially poor
- higher-quality preview and export behavior than a game runtime typically needs

Recommended player layers:

### Preferred runtime path

`ABCJinglePlayer.swift`

- Input: `ABCTune` or flattened timed note events.
- Playback engine: `AVAudioEngine` plus `AVAudioUnitSampler` or a small built-in soundfont/instrument strategy.
- Support start/stop/seek-preview for very short jingles.
- Handle multiple voices by routing simultaneous notes correctly.

### Debug/export path

- Generate MIDI via `ABCMIDIGenerator`.
- Optionally write to disk with `ABCMIDIWriter`.
- Optionally preview through `AVMIDIPlayer` as a diagnostic path.

This split lets us preserve parity without coupling the shipped UX to MIDI files.

## Jingle Cards Integration Plan

Add ABC jingles as a reusable app asset, similar to a compact reusable sound element rather than paragraph audio.

### Data model

Add a model such as:

```swift
struct ABCJingleCard: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var abcSource: String
    var isEnabled: Bool
    var category: String
    var createdAt: Date
    var updatedAt: Date
    var lastValidatedAt: Date?
    var cachedPreviewPath: String?
    var cachedMIDIPath: String?
}
```

Optional later metadata:

- tags
- duration estimate
- default instrument preset
- usage point, such as intro, transition, outro, emphasis

### Service layer

Create `ABCJingleService` with responsibilities:

- validate ABC text
- compile to `ABCTune`
- produce preview playback events
- optionally render/export MIDI
- cache preview artifacts
- report parse errors with line numbers

### View model integration

Add jingle-card state to `ProjectViewModel` or a focused sub-view-model:

- list cards
- add/edit/delete/duplicate cards
- validate card
- preview card
- insert card into export sequence later

### UI scope

Minimum viable UI:

- Jingles section in the sidebar or settings pane
- list of saved jingle cards
- editor sheet with name plus ABC text
- Validate button
- Preview button

Do not try to build a notation editor first. Plain ABC text with validation is enough for v1.

## Phased Implementation Plan

### Phase 0. Freeze the Zig oracle

Before changing Swift behavior:

- Inventory the Zig parser and MIDI tests.
- Convert the test cases into a parity checklist.
- Keep a simple matrix of implemented vs missing behaviors.

Deliverable:

- internal parity checklist covering parser and timing behavior

### Phase 1. Finish the Swift parser core

Implement:

- full `ABCTypes` parity
- `ABCVoiceManager`
- `ABCMusicParser`
- upgraded `ABCParser`

Gate:

- Swift parser passes direct ports of the Zig parser tests.

Expected output:

- parse ABC into `ABCTune` with correct `features`, `voices`, timestamps, and metadata

### Phase 2. Port MIDI generation and writer

Implement:

- `ABCMIDIGenerator`
- `ABCMIDIWriter`

Gate:

- Swift timing and track-generation tests pass ports of `midi_timing_test.zig`.

Expected output:

- deterministic track/event output and optional `.mid` export

### Phase 3. Build the app-facing jingle player

Implement:

- `ABCJinglePlayer`
- `ABCJingleService`

Gate:

- short jingles preview reliably in-app
- stop/restart behavior is stable
- multi-voice overlap works

Expected output:

- VoiceOverStudio can preview a jingle card without leaving the app

### Phase 4. Add jingle cards to the product

Implement:

- jingle card model
- save/load support
- validation UX
- preview UX

Gate:

- user can create, edit, save, validate, and preview jingle cards

Expected output:

- reusable ABC snippets managed as first-class assets

### Phase 5. Sequence integration

After preview works, wire jingles into actual project flow:

- allow jingles to be inserted before paragraph groups, between paragraphs, or at export boundaries
- render jingles into the same final timeline/export pipeline as generated speech

Gate:

- jingles survive project save/load and export in the correct order and duration

## Parity Test Plan

Port the Zig tests into XCTest in batches instead of inventing new high-level tests first.

### Parser parity tests to port first

From `parser_test.zig`:

- dotted note duration
- guitar chord feature emission
- inline tempo feature emission
- tied notes merge
- key signature affects pitch
- repeat expansion duplicates repeated section
- mid-tune key change affects following notes
- broken rhythm pair durations and timestamps
- multi-voice timeline restoration
- tie across barline
- malformed chord recovery
- quoted multi-word voice names
- section-style inline named voices
- bar accidental carry and reset

### MIDI/timing parity tests to port next

From `midi_timing_test.zig`:

- sustained duration for tied notes
- optional guitar chord playback flag
- broken-rhythm timing boundaries
- note-track end-of-track includes trailing rests
- chord notes end together
- tempo-track end-of-track reaches full timeline
- multi-voice overlap gets aligned starts and distinct channels
- tempo changes occur at exact feature boundaries
- three-voice overlap preserves distinct channels

### Recommended testing structure in Swift

- `ABCParserParityTests.swift`
- `ABCMIDITimingParityTests.swift`
- `ABCJingleServiceTests.swift`

Also add fixture-based tests where one ABC string asserts:

- parsed features
- timestamps
- voice IDs
- MIDI event times

## Sequencing With VoiceOverStudio Audio

Jingles should fit the existing app model instead of creating a separate export path.

Recommended rule:

- treat a rendered jingle like a short audio asset that can be inserted into the same sequence/export pipeline already used for paragraph audio

That means later integration should reuse the existing composition/export logic rather than building a separate exporter.

Practical sequence model for later:

- speech paragraph item
- jingle item
- silence item

This will make it easier to place an intro sting, transition cue, or outro motif around paragraph narration.

## Risks

### Biggest functional risks

- subtle timestamp drift if whole-note timing is converted inconsistently
- accidental handling mismatch across bars and key changes
- voice timeline restoration bugs in multi-voice tunes
- mismatch between parser parity and runtime playback if the player interprets durations differently than the MIDI generator

### Product risks

- trying to build notation editing UI before parity is done
- skipping the MIDI layer and losing a strong verification tool
- over-optimizing the player before the parser is trustworthy

## Decisions To Keep Simple

- Keep ABC text editing plain-text for v1.
- Keep the parser behavior close to Zig, even if some code feels more procedural than typical Swift.
- Keep MIDI export as an internal/debug feature at first.
- Keep jingle cards small and reusable, not full arrangement projects.

## Definition Of Done

The port is done when all of the following are true:

- Swift parser behavior matches the Zig oracle for the current parser and timing test suite.
- Swift can generate equivalent note/tempo/time/key track events for representative fixtures.
- VoiceOverStudio can validate and preview ABC jingles in-app.
- Users can save and reuse jingle cards.
- Jingles can be inserted into the project audio flow without breaking the existing paragraph export path.

## Recommended Execution Order

1. Expand `ABCTypes.swift` to true parity.
2. Add `ABCVoiceManager.swift`.
3. Add `ABCMusicParser.swift` and upgrade `ABCParser.swift`.
4. Port parser tests from Zig to XCTest until green.
5. Add `ABCMIDIGenerator.swift`.
6. Add `ABCMIDIWriter.swift`.
7. Port MIDI timing tests until green.
8. Add `ABCJinglePlayer.swift` and `ABCJingleService.swift`.
9. Add `ABCJingleCard` model plus minimal UI.
10. Integrate jingles into project sequencing/export.

## Immediate Next Step

Implement Phase 1 only: finish parser parity and get the Zig parser tests passing in Swift before touching playback UI.