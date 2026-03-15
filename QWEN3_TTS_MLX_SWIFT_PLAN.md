# Qwen3-TTS Fork via MLX Audio Swift

## Purpose

This document describes a Swift-only plan to turn VoiceOverStudio into a Qwen3-TTS-based fork using MLX on Apple Silicon. The target outcome is native, on-device speech generation on macOS without any Python runtime, sidecar process, local REST bridge, cloud dependency, or Sherpa-ONNX runtime.

The recommended path is to integrate `mlx-audio-swift` through Swift Package Manager and use its native Qwen3-TTS model support directly from the app as the only TTS engine.

## Why This Path

VoiceOverStudio is already a native macOS app built with SwiftUI and local llama.cpp. A Python-based TTS bridge would work, but it would weaken the app in the wrong places:

- larger install surface
- more packaging risk
- process lifecycle complexity
- slower startup and worse error handling
- harder App bundle distribution

`mlx-audio-swift` changes the tradeoff. It provides a native Swift SDK for MLX-based audio inference, exposes async/await APIs, and explicitly lists Qwen3-TTS as a supported TTS model. That makes a no-Python implementation realistic.

## Confirmed External Capabilities

Based on current upstream documentation for `mlx-audio-swift`:

- platform: macOS 15+, Apple Silicon required for the Metal 3.2 MLX path
- toolchain: Xcode 15+, Swift 5.9+
- integration: Swift Package Manager
- API style: native async/await
- TTS support: `MLXAudioTTS` module
- Qwen3-TTS support: listed supported model `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`
- model acquisition: automatic download from Hugging Face supported by the library
- streaming generation: supported by the Swift SDK

This is enough to plan a direct Swift integration.

## Product Direction

This is a fork-level change, not a feature flag.

The fork should:

- remove Sherpa-ONNX as a runtime dependency
- remove ONNX/VITS-specific configuration from the UI and data flow
- standardize on Qwen3-TTS through MLX as the single TTS implementation
- preserve the existing paragraph editor, playback, export, and llama.cpp text-improvement flow

This means the app becomes a Qwen TTS desktop authoring tool rather than a generic local TTS frontend.

## Scope

### In Scope

- replace ONNX/Sherpa TTS with Qwen3-TTS via MLX
- support direct text-to-speech generation through MLXAudioTTS
- keep existing paragraph workflow, playback flow, and export flow
- support model download/caching through the Swift package's native behavior

### Out of Scope for Phase 1

- voice cloning UI
- arbitrary voice design prompt workflows
- custom model conversion or quantization UI
- replacing llama.cpp text-improvement flow
- iOS support

## Proposed Architecture

VoiceOverStudio should move from a Sherpa-specific TTS implementation to a Qwen/MLX-native TTS implementation.

### Current State

- `ProjectViewModel` coordinates generation
- `TTSService` wraps Sherpa-ONNX VITS
- `Paragraph` stores text, speaker id, speed, gap, and generated audio path

### Target State

- `ProjectViewModel` talks directly to a Qwen-focused TTS service or a minimal protocol abstraction if that improves testability
- `MLXQwenTTSService` becomes the app's only TTS implementation using `MLXAudioTTS`
- UI exposes Qwen-compatible voice options and removes backend switching entirely
- all ONNX/VITS model-path setup is removed from the product surface

### Service Interface

```swift
protocol TTSBackendProtocol: AnyObject {
    var voiceOptions: [VoiceOption] { get async throws }
    func warmupIfNeeded() async throws
    func generateAudio(
        text: String,
        voice: VoiceOption,
        speed: Float,
        stylePrompt: String?
    ) async throws -> URL
}
```

This can remain as a thin protocol if the team wants test seams, but there is no need to preserve a multi-backend architecture in the product.

## Recommended Dependency Change

Add `mlx-audio-swift` as a Swift Package dependency in `Package.swift`.

### New dependency

```swift
.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main")
```

### New products for the app target

```swift
.product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
.product(name: "MLXAudioCore", package: "mlx-audio-swift"),
```

This should replace the Sherpa dependency while keeping `LLamaC`.

### Dependency removal

Remove the local `SherpaOnnxC` target from `Package.swift` and stop linking against the Sherpa/ONNX libraries.

## Model Choice

Use the smallest supported Qwen3-TTS model first:

- `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`

Reasons:

- materially lower memory pressure than larger bf16 variants
- better first-run download size
- better fit for a desktop app that may coexist with llama.cpp in the same process
- enough quality to validate the backend and UX

Larger or more expressive variants can be added later behind settings.

## Voice Strategy

Phase 1 should support the built-in voices exposed by the Qwen3-TTS model path used through MLX.

The app already has a `VoiceOption` concept. Reuse that rather than inventing a second voice model.

### Proposed `VoiceOption` shape

```swift
struct VoiceOption: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let backendVoiceID: String
}
```

Notes:

- remove `sid` entirely once Sherpa is removed
- Qwen/MLX uses `backendVoiceID`

## Paragraph Model Changes

The existing paragraph model is close to what is needed. A Swift-only MLX path benefits from one new field:

```swift
var stylePrompt: String = ""
```

Purpose:

- optional natural-language style instruction for future Qwen3-TTS features
- directly aligned with Qwen3-TTS capabilities

Phase 1 may keep the field hidden in the UI if the chosen upstream Qwen model path does not expose style prompting cleanly. The data model should still be prepared for it.

## Service Design

### 1. Replace Existing TTS Service with `MLXQwenTTSService`

New service file:

- `Sources/VoiceOverStudio/Services/MLXQwenTTSService.swift`

Responsibilities:

- lazily load the Qwen3-TTS model through `MLXAudioTTS`
- fetch and cache available voices if exposed by the library
- generate waveform arrays from text
- write waveform to a WAV file in the app temp/output area
- surface engine/model errors in app-native error messages

### 2. Audio File Output

The service should return a generated file URL, not raw audio buffers, so it matches the current playback/export pipeline.

Recommended flow:

1. generate audio array from MLX model
2. write `.wav` to `FileManager.default.temporaryDirectory`
3. hand that URL back to `ProjectViewModel`
4. reuse current playback and export logic unchanged

This lets the TTS engine change without forcing an export/playback rewrite.

## ViewModel Changes

`ProjectViewModel` should own Qwen model warmup, voice loading, and generation.

### New state

```swift
@Published var availableVoices: [VoiceOption] = []
@Published var isWarmingUpTTS: Bool = false
```

### Responsibilities

- initialize the MLX Qwen service on demand
- warm the model without blocking the UI
- load voice options once the model is available
- generate audio for all paragraph requests through the Qwen service
- migrate any old paragraph voice ids if prior transcript files still exist

## UI Changes

The UI should remove TTS-backend selection entirely. The fork has one TTS engine.

### Sidebar changes

- remove ONNX model path fields
- remove tokens/data-dir/lexicon controls
- show current Qwen model readiness state
- show model warmup/loading status for MLX
- optionally show the selected Qwen model id if multiple model variants are supported later

### Paragraph row changes

- keep voice picker
- keep speed control
- optionally expose `stylePrompt` for Qwen paragraphs when supported by the selected model path

## Packaging and Distribution Implications

This Swift-only plan is materially better for packaging than a Python bridge, and simpler than carrying both MLX and ONNX TTS stacks.

### Benefits

- single-process app
- native Swift dependency graph
- easier app bundling story
- smaller runtime surface than shipping both Sherpa and MLX TTS

### Costs

- app binary and first-run download behavior become more dependent on MLX and Hugging Face caching behavior
- memory usage rises because Qwen3-TTS and llama.cpp may coexist in-process
- app launch must not block on Qwen model loading
- migration is breaking for users who currently depend on custom ONNX voices

### Packaging rule

Model download must remain lazy and user-driven. Do not try to embed Qwen3-TTS weights inside the app bundle.

## Performance Expectations

On Apple Silicon, MLX should be a better fit than a Python+Transformers route, but Qwen3-TTS is still a large generative model. Plan for:

- warmup latency on first use
- heavier memory use than the old VITS path
- slower per-paragraph generation than the old Sherpa path on smaller machines

That means the product should frame Qwen TTS as a quality-first engine, and the UI should set expectations around warmup time and generation speed.

## Risk Register

### 1. Upstream API volatility

`mlx-audio-swift` is new and moving quickly. Public APIs may change.

Mitigation:

- isolate usage in one backend file
- avoid spreading direct MLX types across the app

### 2. Voice enumeration uncertainty

The docs confirm Qwen3-TTS support but do not fully specify how voice metadata is surfaced in Swift.

Mitigation:

- phase 1 can ship with a curated voice list if needed
- service can internally map app voice ids to upstream strings

### 3. Memory contention with llama.cpp

Running local LLM polishing and Qwen3-TTS in one process can pressure unified memory.

Mitigation:

- lazy model loading
- optional backend-only warmup
- release inactive MLX model if memory pressure appears in testing

### 4. Breaking migration from ONNX

Removing ONNX support will invalidate current TTS settings and may make older transcript voice ids stale.

Mitigation:

- remove obsolete settings cleanly
- map old transcript voices to a default Qwen voice on load
- clearly document that this fork no longer supports Sherpa/ONNX voice packages

### 5. App responsiveness during generation

Heavy generation must not stall the UI.

Mitigation:

- keep generation async
- update paragraph state on the main actor only
- consider task cancellation hooks for long-running generations

## Implementation Phases

### Phase 1: Remove ONNX TTS and Add MLX Dependency

1. Add `mlx-audio-swift` to `Package.swift`
2. Remove `SherpaOnnxC` from `Package.swift`
3. remove Sherpa/ONNX-specific linker settings and configuration paths
4. optionally keep a small protocol abstraction for testability

### Phase 2: Native MLX Qwen Backend

1. Create `MLXQwenTTSService.swift`
2. Load `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`
3. Generate WAV output into temp files
4. Hook service into paragraph generation flow

### Phase 3: UI and Model Cleanup

1. Remove ONNX model-path controls from the sidebar
2. Add Qwen model readiness/warmup status
3. Load and display Qwen voices
4. Optionally add `stylePrompt` field for Qwen paragraphs

### Phase 4: Hardening

1. verify model download/cache behavior on a clean machine
2. test app responsiveness during long generations
3. test export flow with regenerated audio
4. validate transcript migration behavior from old ONNX-era data

## Concrete File Plan

### Files to update

- `Package.swift`
- `Sources/VoiceOverStudio/ViewModels/ProjectViewModel.swift`
- `Sources/VoiceOverStudio/Models/Paragraph.swift`
- `Sources/VoiceOverStudio/ContentView.swift`
- `Sources/VoiceOverStudio/Services/TTSService.swift` or replace with a Qwen-specific service

### Files to add

- optional: `Sources/VoiceOverStudio/Services/TTSBackendProtocol.swift`
- `Sources/VoiceOverStudio/Services/MLXQwenTTSService.swift`

## Suggested Acceptance Criteria

The work should be considered complete when all of the following are true:

1. the app builds with `mlx-audio-swift` added through SwiftPM
2. the app no longer depends on Sherpa-ONNX for TTS
3. the app warms the Qwen model without freezing the UI
4. a paragraph can be generated to a WAV file using Qwen3-TTS
5. generated WAV plays in the existing playback flow
6. full-sequence export still works unchanged
7. obsolete ONNX settings are removed and old transcript files degrade gracefully

## Recommendation

Proceed with the fork as a single-engine Qwen3-TTS app and implement TTS through `mlx-audio-swift` as the native runtime.

Do not keep Sherpa/ONNX around unless a concrete blocker appears in the MLX path. Given the fork direction, carrying both engines would add maintenance cost without product value.