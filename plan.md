# Qwen Voice Controls and Short Reference Voice Enrollment Plan

## TL;DR

Replace unreliable freeform Qwen voice prompting with structured, constrained voice controls that map more predictably to the model. Keep the current single reference voice design, shorten reference enrollment to about 10 seconds of speech instead of the current long script flow, and align UI, persistence, prompt composition, and recorder guidance around that smaller, more stable workflow.

## Goals

- Replace per-paragraph freeform voice instruction text with structured fields and fixed choices.
- Add a dedicated right-side sliding pane for configuring the currently selected voice.
- Keep prompt generation predictable and Qwen-oriented by using acoustic descriptors rather than open-ended prose.
- Preserve the current single reference voice model for now.
- Reduce reference enrollment from the current long read to a target of roughly 10 seconds of cleaned speech.
- Persist voice configurations in application-level settings so they survive across launches.
- Keep backward compatibility for existing saved transcript files where practical.

## Current Problems

- Freeform `voiceInstructions` does not produce stable enough results.
- The app currently lets users type arbitrary prose, which makes prompt behavior inconsistent and hard to tune.
- Reference voice enrollment currently uses a much longer script pattern than needed for the intended workflow.
- UI guidance, generated script length, and recorder expectations are not aligned around a short sample.
- Voice controls are embedded inline in each paragraph row, which is not a good fit for a richer configuration workflow.
- Voice configuration is not yet treated as a reusable application-level asset that can persist over time.

## Proposed Direction

### 1. Replace freeform instructions with structured voice controls

Instead of a large inline freeform text box, move voice configuration into a dedicated right-side sliding pane that edits the currently selected voice configuration and produces one derived Qwen prompt string.

Recommended field groups:

- **Anchor**
	- adult woman
	- adult man
	- middle-aged woman
	- middle-aged man
	- neutral narrator

- **Timbre**
	- warm
	- deep
	- bright
	- breathy
	- raspy
	- crisp
	- gravelly
	- smooth

- **Prosody**
	- conversational
	- rhythmic
	- fluid
	- monotone
	- staccato
	- measured

- **Pacing**
	- brisk
	- steady
	- relaxed
	- deliberate
	- pauses between phrases

- **Emotional contour**
	- warm
	- calm
	- tense
	- melancholic
	- enthusiastic
	- playful
	- flat

- **Delivery strength**
	- subtle
	- moderate
	- strong

These values should be combined into one derived prompt string for Qwen, instead of exposing a raw text field as the main control surface.

### 2. Add a right-side sliding voice configuration pane

The app should add a new right-side sliding pane dedicated to voice configuration.

The pane should:

- open for the currently selected paragraph or selected voice preset
- show all structured voice controls in one focused place
- let the user review and modify the selected voice configuration without crowding the paragraph editor
- support a workflow where users intentionally configure a selected voice rather than casually typing ad hoc instructions inline

The paragraph editor should keep voice selection lightweight, while detailed tuning moves into this pane.

### 3. Generate one consistent Qwen-facing prompt string

The app should continue sending a single `voice` string to the model, but that string should be assembled from structured fields rather than typed freeform prose.

Target format:

1. anchor
2. primary timbre
3. prosody
4. pacing
5. emotional contour
6. delivery strength / emphasis guidance
7. hard constraints for voice consistency

Example derived prompt:

> Middle-aged woman, warm timbre, fluid prosody, deliberate pacing, calm emotional tone, moderate expressiveness. Maintain one stable speaker identity for the full utterance. Keep articulation consistent and avoid drifting in age, gender, accent, or vocal texture.

This keeps the prompt descriptive, acoustic, and repeatable.

### 4. Persist voice configurations in app settings

Voice configurations should be saved in application configuration so they persist over time.

That means:

- structured voice settings should not live only in transient UI state
- the app should save reusable voice configuration data in app-level persistent storage
- saved configurations should be available across launches
- a paragraph should reference a selected saved voice configuration rather than storing only an inline freeform prompt

The first version can remain simple:

- system-defined built-in voices remain available
- user-edited structured configurations are persisted locally in app settings
- one selected configuration can be applied to many paragraphs

This gives the app durable, reusable voice behavior without introducing a full voice-library product surface.

### 5. Keep one reference voice only

The app should keep the current single reference voice approach for now.

That means:

- one saved reference voice profile on disk
- one reference voice option in the picker
- no multi-profile management yet
- no per-paragraph reference voice recordings

This keeps persistence, picker behavior, and generation flow simple while the prompt system is being stabilized.

### 6. Shorten reference enrollment to about 10 seconds

The current reference voice script flow is too long for the intended design. The new target should be approximately 10 seconds of natural speech after trimming.

Recommended target window:

- ideal: 8 to 12 seconds
- acceptable: 6 to 15 seconds

The default script and AI-generated script should both be redesigned around this shorter target.

Instead of two long paragraphs, use:

- one short paragraph, or
- two very short sentences if needed for variety

The reference script should still contain:

- varied vowels and consonants
- a natural speaking rhythm
- one or two numbers or names if helpful
- plain punctuation only

But it should no longer ask the user to read a long 120 to 180 word passage.

### 7. Align the design-then-clone workflow

The intended workflow should be:

1. choose structured voice controls for the target sound
2. optionally use Voice Design mode to create a stable target style
3. record one short reference voice sample
4. use that single reference voice for cloning and stable reuse

The app should not attempt to support multiple cloning workflows or multiple reference identities yet.

## File-Level Plan

### Data model

Update `Paragraph` so it can reference a reusable saved voice configuration rather than owning a freeform prompt blob.

Primary file:

- `Sources/VoiceOverStudio/Models/Paragraph.swift`
- `Sources/VoiceOverStudio/Models/ReferenceVoiceProfile.swift`

Planned changes:

- add Codable enums or string-backed structured properties for anchor, timbre, prosody, pacing, emotional contour, and delivery strength
- introduce a stable voice configuration identity that paragraphs can reference
- separate paragraph-level voice selection from application-level saved voice configuration data
- keep legacy `voiceInstructions` decoding support for backward compatibility
- derive the final prompt later in `TTSService`

#### Proposed `VoiceConfiguration` model

Create a new application-level model that represents one reusable saved voice configuration.

Suggested shape:

```swift
struct VoiceConfiguration: Identifiable, Codable, Hashable {
	var id: UUID
	var name: String
	var baseVoiceID: String
	var anchor: VoiceAnchor
	var timbre: VoiceTimbre
	var prosody: VoiceProsody
	var pacing: VoicePacing
	var emotionalContour: VoiceEmotion
	var deliveryStrength: VoiceDeliveryStrength
	var isBuiltIn: Bool
	var createdAt: Date
	var updatedAt: Date
}
```

Suggested supporting enums:

```swift
enum VoiceAnchor: String, Codable, CaseIterable {
	case neutralNarrator
	case adultWoman
	case adultMan
	case middleAgedWoman
	case middleAgedMan
}

enum VoiceTimbre: String, Codable, CaseIterable {
	case warm, deep, bright, breathy, raspy, crisp, gravelly, smooth
}

enum VoiceProsody: String, Codable, CaseIterable {
	case conversational, rhythmic, fluid, monotone, staccato, measured
}

enum VoicePacing: String, Codable, CaseIterable {
	case brisk, steady, relaxed, deliberate, pausesBetweenPhrases
}

enum VoiceEmotion: String, Codable, CaseIterable {
	case warm, calm, tense, melancholic, enthusiastic, playful, flat
}

enum VoiceDeliveryStrength: String, Codable, CaseIterable {
	case subtle, moderate, strong
}
```

Rationale:

- `name` gives the user a stable saved identity such as “Warm Documentary” or “Gentle Female Narrator”.
- `baseVoiceID` preserves compatibility with existing built-in voice choices.
- the structured enums constrain the prompt surface to tested, reusable settings.
- timestamps make local editing and future migration simpler.

#### Proposed `Paragraph` reference model

Instead of storing the whole voice definition in every paragraph, a paragraph should reference a saved voice configuration by identity.

Suggested shape:

```swift
struct Paragraph: Identifiable, Codable {
	var id: UUID
	var text: String
	var voiceConfigurationID: UUID?
	var voiceID: String
	var gapDuration: Double
	var speed: SpeedPreset
	var pitch: PitchPreset
	var audioPath: String?
	var outputFilename: String
}
```

Reference strategy:

- `voiceConfigurationID` points at the saved application-level configuration the paragraph uses.
- `voiceID` can remain temporarily for migration and built-in fallback behavior.
- if `voiceConfigurationID` is missing, the app can resolve to a default built-in configuration.
- paragraphs should not be the primary home of full voice-style settings.

This keeps paragraph documents smaller and lets users improve a saved voice configuration once and reuse it across many paragraphs.

### Paragraph editor UI

Replace the current freeform voice instructions editor with lightweight voice selection plus an entry point into a right-side sliding configuration pane.

Primary file:

- `Sources/VoiceOverStudio/ContentView.swift`

Likely supporting files:

- `Sources/VoiceOverStudio/VoiceOverStudioApp.swift`
- `Sources/VoiceOverStudio/ViewModels/ProjectViewModel.swift`

Planned changes:

- remove the large freeform text editor as the primary UI
- keep the paragraph row focused on selecting a voice configuration and opening the configuration pane
- add a right-side sliding pane that contains the structured controls for the selected voice
- add clear affordances like “Configure Voice” or “Edit Voice Details” for the selected voice
- provide brief helper text that explains the controls are acoustic, not narrative
- keep advanced freeform authoring out of scope for this phase

### Application configuration persistence

Persist reusable voice configurations in application settings.

Primary files:

- `Sources/VoiceOverStudio/ViewModels/ProjectViewModel.swift`
- `Sources/VoiceOverStudio/VoiceOverStudioApp.swift`

Likely new model/config file:

- `Sources/VoiceOverStudio/Models/VoiceConfiguration.swift`

Planned changes:

- create a persistent app-level model for saved voice configurations
- load and save the configurations from app settings or a local app-managed config store
- preserve the selected/default configuration across launches
- allow paragraphs to bind to a saved configuration identity
- keep the persistence approach simple and local-only

#### Proposed persisted application config shape

For the first version, persist a small app-level configuration object that owns saved voice configurations.

Suggested shape:

```swift
struct VoiceConfigurationStore: Codable {
	var selectedVoiceConfigurationID: UUID?
	var configurations: [VoiceConfiguration]
}
```

Behavior:

- store built-in defaults plus any user-edited copies in one local config payload
- preserve the last selected configuration across launches
- allow the app to restore the voice pane state cleanly on startup
- keep the store separate from transcript documents so voice definitions behave like app preferences, not project content

Persistence options:

- small JSON file under the app-managed data directory, or
- serialized data in application settings if size and editing needs stay small

Preferred direction:

- use a small JSON config file if we expect the model to grow over time
- use settings storage only if we are confident the object remains very small and simple

### Prompt composition

Refactor prompt assembly so structured fields are the only main source of voice guidance.

Primary file:

- `Sources/VoiceOverStudio/Services/TTSService.swift`

Planned changes:

- replace freeform-driven `composeVoicePrompt` behavior with a deterministic prompt builder
- build the prompt from the selected saved voice configuration
- keep the final model call using one `voice` string
- preserve consistency guardrails to reduce voice drift
- keep `refAudio` and `refText` support for the single reference voice flow

### Reference voice script generation

Shrink both the built-in default script and the LLM-generated script prompt.

Primary files:

- `Sources/VoiceOverStudio/ViewModels/ProjectViewModel.swift`
- `Sources/VoiceOverStudio/Services/LLMService.swift`

Planned changes:

- replace the current long default script with a short ~10 second version
- change AI script generation instructions so they target a short clip instead of two long paragraphs
- update copy that currently implies a longer reading session

### Reference voice recording rules

Bring recorder validation and UX guidance into alignment with the new short sample target.

Primary file:

- `Sources/VoiceOverStudio/Services/ReferenceVoiceRecorder.swift`

Planned changes:

- validate recorded duration against a target window centered around ~10 seconds
- continue trimming silence and normalizing audio
- surface clear feedback when the cleaned clip is too short or too long

### Reference voice state and workflow

Keep the current single-profile state model and make that an explicit scope decision.

Primary files:

- `Sources/VoiceOverStudio/ViewModels/ProjectViewModel.swift`
- `Sources/VoiceOverStudio/Models/ReferenceVoiceProfile.swift`

Planned changes:

- keep one global reference voice profile
- keep one reference voice picker option
- avoid adding profile libraries or multi-voice management in this phase

### Sliding pane state and selection model

Add explicit UI state for selecting and editing the active voice configuration.

Primary files:

- `Sources/VoiceOverStudio/ViewModels/ProjectViewModel.swift`
- `Sources/VoiceOverStudio/ContentView.swift`

Planned changes:

- track which paragraph is currently editing voice details
- track whether the right-side voice pane is open
- bind the pane to the selected saved voice configuration
- keep the interaction model compatible with the existing split-view layout

Suggested interaction model:

- selecting a paragraph shows which saved voice configuration it uses
- pressing “Configure Voice” opens the right-side pane
- the pane edits the selected saved voice configuration directly
- changes are persisted to application config automatically
- any paragraph using that configuration benefits from the updated settings
- if a user wants a variation, they should duplicate the saved voice configuration rather than editing per-paragraph freeform text

## Migration and Backward Compatibility

- Existing transcript files may still contain `voiceInstructions`.
- The app should continue decoding old data without failing.
- Legacy freeform instructions can be mapped to defaults or carried as a compatibility field during transition.
- Existing paragraphs may need migration from inline voice data to a saved voice configuration reference.
- The app should create a reasonable default saved configuration when opening older projects.
- Old projects should still open even if they do not immediately map perfectly into the new structured model.

Suggested migration path:

1. ship a default set of built-in `VoiceConfiguration` records that mirror the current voice presets
2. when an older paragraph has `voiceID` but no `voiceConfigurationID`, map it to the matching built-in configuration
3. when an older paragraph contains legacy `voiceInstructions`, either:
	- preserve them as compatibility-only data during transition, or
	- convert them into a duplicated custom configuration if we later add a safe mapping path
4. once migrated, save the paragraph using `voiceConfigurationID` as the main reference

## Success Criteria

- Users select voice style through structured choices instead of raw prompt writing.
- Users can open a right-side pane to configure the selected voice in a focused workflow.
- Voice configurations persist across launches because they are stored in application configuration.
- Generated voices are more stable and repeatable than with freeform instructions.
- The app still supports exactly one reference voice.
- Reference enrollment takes about 10 seconds of speech instead of a long scripted read.
- The default script, AI-generated script, UI text, and recorder validation all point at the same short enrollment target.

## Out of Scope

- multiple saved reference voices
- per-project reference voice libraries
- per-paragraph reference audio profiles
- unconstrained advanced freeform prompt authoring as a first-class workflow
- multi-profile voice library management beyond simple saved configurations
- a larger redesign of export, playback, or transcript document structure beyond what is needed for the new prompt controls

## Open Questions

1. Should a hidden or advanced fallback freeform field remain available for debugging, or should structured controls be the only supported input path?
2. Should the recorder enforce the 10-second target strictly, or should it guide the user with warnings while still allowing slightly shorter or longer clips?
3. Should legacy `voiceInstructions` be mapped heuristically into the new structured categories, or simply preserved as compatibility-only data during migration?
4. Should saved voice configurations live in `AppStorage`-style settings, a JSON config file, or another small local persistence layer?
