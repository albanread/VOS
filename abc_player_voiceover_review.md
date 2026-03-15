# ABC Player Review for VoiceOverStudio

This note reviews the imported game-focused ABC player document in [reference/ABCplayer.md](/Volumes/xb/voiceover/reference/ABCplayer.md) and identifies where the VoiceOverStudio and podcast use case should intentionally diverge.

## Framing

The imported ABC player design is a useful starting point because it is:

- deterministic
- compact
- easy to validate
- structured around short cues and reliable playback

Those are all still valuable for jingles, transitions, intros, outros, and podcast punctuation.

What should change is the product target. The original document assumes a game runtime where cues are state-driven, musically sparse, and tolerant of synthetic playback shortcuts. VoiceOverStudio needs a more editorial, spoken-word-aware playback model.

## What Carries Over Well

These ideas should stay:

- Keep ABC as a compact authoring format for short cues.
- Treat validation and predictable playback as first-class.
- Preserve slot-like caching semantics even if the implementation becomes Swift-native objects instead of game slots.
- Keep multi-voice support because melody, bass, and light percussion remain useful for jingles.
- Preserve MIDI export as a debugging and interchange surface.

## What Should Change For Voice Over And Podcasts

### 1. Editorial timing matters more than loopability

The game player emphasizes loops and beds. VoiceOverStudio should prioritize:

- precise intro and outro lengths
- clean cadence endings
- deterministic tail duration
- previewing how a jingle lands before speech starts or after speech ends

Recommendation:

- Add duration estimation and rendered tail reporting to the ABC service.
- Support pre-roll, post-roll, and fade metadata around jingles.
- Prefer one-shot cue workflows over loop-first workflows in the UI.

### 2. Percussion should be lightweight and speech-safe

Percussion is useful here, but it should not behave like game combat or level percussion.

Recommendation:

- Keep percussion channel support and drum-kit program selection.
- Add a speech-safe percussion preset set: ticks, snaps, shaker, soft kick, light tom, muted hit.
- Avoid dense hi-hat or transient-heavy kits by default.
- Add a policy layer that can reject or warn on over-busy percussion patterns for spoken-word presets.

### 3. Instrument defaults should favor spoken-word compatibility

The game document assumes bright lead, bass, and pad usage. For voice-over and podcasts, default programs should emphasize clarity and low masking.

Recommendation:

- Add named VoiceOverStudio presets like `podcast_intro`, `soft_transition`, `uplift_tag`, `news_sting`, `educational_bumper`.
- Bias defaults toward pluck, mallet, light electric piano, soft synth bell, muted bass, and restrained percussion.
- Avoid harsh brass, long sustaining pads, and dense low-mid content as defaults.

### 4. Dynamics should become part of product behavior, not just raw MIDI values

`%%MIDI velocity` is useful, but editorial users think in terms like subtle, confident, celebratory, understated.

Recommendation:

- Keep raw MIDI directives for parity.
- Add a higher-level mapping layer from style presets to instrument, velocity range, and optional compression/EQ recommendations.
- Consider a limiter or loudness-normalization stage in preview/export so cue loudness is consistent around speech.

### 5. Rendering quality matters more than game-runtime immediacy

A game engine can accept simpler playback if it is responsive. VoiceOverStudio should optimize more for sound quality and export consistency.

Recommendation:

- Prefer offline or semi-offline render paths for final export.
- Keep real-time preview, but allow higher-quality render for publish/export.
- Make MIDI export and direct sampler playback produce consistent cue timing.

### 6. The app should support reusable cue templates, not just raw ABC text

Game usage is code-embedded. VoiceOverStudio should expose reusable editorial assets.

Recommendation:

- Store jingles as cards with name, category, tags, estimated duration, instrumentation preset, and speech-safe rating.
- Support dual authoring on each card: an English prompt brief for AI-assisted generation and editable ABC source for deterministic review and manual refinement.
- Add validation feedback for too-long intros, too-dense textures, and excessive overlap with narration windows.
- Support template-driven generation of common cue shapes such as 2-note stings, 4-beat risers, short logo mnemonics, and outro tags.

### 7. We should be stricter than the game player in a few places

The game parser is intentionally forgiving. That is acceptable in code-first experimentation, but less ideal in an editorial tool.

Recommendation:

- Keep parser parity at the core layer.
- Add a higher-level validation pass in VoiceOverStudio that surfaces warnings for questionable but parseable input.
- Examples: missing tempo, too many simultaneous voices, excessive duration, no clear ending cadence, percussion without melodic anchor, overly low bass range.

## Specific Product Improvements Worth Adding

These are concrete improvements beyond the original Zig player model:

1. Jingle duration analyzer
   - Compute total cue length, attack profile, sustain density, and tail length.

2. Speech overlap safety checks
   - Flag cues that occupy too much low-mid energy or run too long for typical intro/outro windows.

3. Preset-aware orchestration
   - Map editorial intent to safe instrument and percussion defaults.

3a. Prompt-to-ABC workflow
   - Let users describe the jingle in plain English first, then let the assistant produce editable ABC as the durable representation.
   - Preserve both the original prompt brief and the resulting ABC on the card so users can iterate in either direction.

4. Preview variants
   - Full preview
   - melody only
   - percussion muted
   - speech-safe mix preview

5. Better export targets
   - MIDI for debugging/interchange
   - rendered WAV or CAF for app use
   - cached preview assets for instant UI playback

6. Explicit cue roles
   - intro
   - transition
   - bumper
   - outro
   - emphasis sting

## Engineering Takeaway

The Zig/game player remains a good base architecture for:

- parsing
- timing
- multi-voice structure
- MIDI generation
- deterministic playback semantics

But the new app should add an editorial layer above it rather than reproducing the game workflow exactly.

The right model is:

- Zig parity core for correctness
- Swift-native render and validation layer for product quality
- VoiceOverStudio cue presets and card UX for spoken-word workflows

## Recommended Next Implementation Steps

1. Add a cue-analysis layer on top of `ABCTune` that computes duration, tail, voice density, percussion usage, and rough speech-safety warnings.
2. Define a first set of VoiceOverStudio jingle presets, including percussion-safe templates.
3. Add a preview/export service that can render both MIDI and app-native preview assets.
4. Keep porting remaining Zig edge cases, but do not stop at parity alone; add editorial validation once the core is stable.
