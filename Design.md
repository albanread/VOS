# VoiceOverStudio — Design Doc

## Purpose
Mac app (Apple Silicon, macOS 14+) for creating voice-overs locally. Users create paragraphs with text, pick a voice, set an output filename, generate and preview audio, and export a full sequence with configurable gaps. No Python dependency in the final app.

## Goals
- Local-only inference: TTS via Qwen3-TTS on MLX; LLM via llama.cpp (GGUF) for text polishing.
- Paragraph-centric workflow: track text, selected voice preset, output file name, generation state, and produced audio path.
- Playback and sequencing: play individual paragraphs and export a stitched timeline with per-paragraph gaps.
- Simple configuration: user-provided GGUF path plus a configurable Qwen model repo selected for the machine tier.
- Mac-native UX: SwiftUI app with no Python bridge, no helper daemon, and no cloud dependency.

## Current Status (March 2026)
- Implemented with real native engines:
  - `llama.cpp` built via CMake and linked through local `LLamaC` module.
  - `mlx-audio-swift` and `mlx-swift` linked through SwiftPM for Qwen3-TTS generation.
- Implemented core features:
  - Per-paragraph text, Qwen voice preset, output filename, gap, and speed.
  - Per-paragraph generate/playback and “Generate All”.
  - Transcript save/load (JSON) with backward-compatible paragraph decoding.
  - Export full sequence to M4A or WAV with per-paragraph gaps.
  - Managed GGUF download plus configurable Qwen model repo selection.
  - Paragraph duplicate and list reordering hooks.
- Remaining blockers are primarily packaging/polish, not core functionality.

## Non-Goals
- Cloud inference or online services.
- iOS/iPadOS builds.
- Python scripts or CLI tooling in the shipped app.

## Constraints and Assumptions
- Running on Apple Silicon; GGUF remains the local LLM format while TTS runs through MLX-compatible Qwen repositories.
- Models are stored outside the app bundle; settings are persisted via AppStorage/UserDefaults.
- Audio export uses AVFoundation; resulting file written to user-selected location (default Downloads).
- llama.cpp remains a local native build; Qwen TTS comes from SwiftPM packages plus remote Hugging Face model repos resolved at runtime.
- App should guide users to obtain models: provide recommended GGUF downloads and recommended Qwen model repos for each machine tier.

## Architecture Overview
- UI: SwiftUI (single-window macOS app) with split view: settings sidebar + paragraph list.
- ViewModel: `ProjectViewModel` manages paragraphs, engine initialization, generation, playback, sequencing/export, and status.
- Services:
  - `TTSService` wraps MLX Qwen3-TTS model loading and wav generation per paragraph.
  - `LLMService` wraps llama.cpp; used for optional text improvement.
- Audio pipeline: per-paragraph wav output (48 kHz, mono) to temp folder; export merges tracks with gaps via `AVMutableComposition` -> `.m4a` (AAC 48 kHz) with optional WAV export for lossless ingest.
- Persistence: paragraphs held in-memory for now; optional future Project file (JSON) for saving/restoring sessions.
- Persistence: paragraphs are also saved/loaded as transcript JSON so voice presets, gaps, and filenames survive between runs.

## Data Model
- `Paragraph` (Identifiable, Codable)
  - `id: UUID`
  - `text: String`
  - `voiceId: String` (Qwen voice preset identifier)
  - `gapDuration: Double` (seconds of silence after paragraph)
  - `audioPath: String?` (generated wav path)
  - `isGenerating: Bool` (UI state)
- Potential `Project` (future): name, outputDir, paragraphs, createdAt/updatedAt.

## User Flows
1) Configure models: user sets an LLM GGUF path and a Qwen model repo, then initializes the engines.
2) Add/edit paragraphs: enter text, choose a prompt-based voice preset, adjust gap, and set an output filename.
3) Optional: Improve text via LLM (local inference) per paragraph.
4) Generate audio: per paragraph, uses TTS; shows progress; stores `audioPath`; status updates.
5) Preview: play paragraph audio inline.
6) Export sequence: merge generated clips in order with gaps; write `.m4a` to chosen location; show completion status.
7) Model fetch/update: from Settings, user downloads the recommended GGUF and selects or edits the recommended Qwen model repo.

## UI Layout (SwiftUI)
- Sidebar: app title, fields for model paths, Initialize button, Export button, status indicator.
- Main pane: list of `ParagraphRow`s with text editor, voice picker, gap field, improve/generate/play buttons, readiness badge.
- Toolbar: add/delete paragraph controls.

## Integration Details
- TTS: MLX Audio Swift loads a Qwen3-TTS repository and generates speech from prompt-based voice descriptors.
- LLM: llama.cpp bindings; load GGUF (Apple Silicon optimized); context size ~2048; non-streaming improveText helper; ensure cleanup on deinit.
- Model acquisition UX: Settings panel provides recommended GGUF downloads and machine-tier-based Qwen repo defaults.
- File IO: save paragraph wav to `FileManager.default.temporaryDirectory` or user-selected output dir; on export prompt for destination if missing permissions.
- Audio join: `AVMutableComposition` + `insertEmptyTimeRange` for gaps; export via `AVAssetExportSession` to `.m4a` (AAC 48 kHz mono). Offer WAV 48 kHz export as an option for NLEs that prefer lossless ingest.

## Persistence Plan
- Short term: AppStorage for model settings; paragraphs live in-memory while the app is open.
- Near term: keep transcript save/load (Project JSON via FileDocument) storing paragraph order, text, voiceId, gap, chosen output filename, and existing audio paths; on load, if audio is missing, allow re-generate.
- Consider versioned file format for forward compatibility.

## Performance and UX
- Ensure engine init is async and gated; disable generate/export buttons while initializing.
- Use `@MainActor` for UI mutations; keep heavy work off main thread.
- Provide status messages and minimal progress indicators per paragraph.

## Testing Plan
- Unit: Paragraph serialization, filename defaults, gap math for composition timeline.
- Integration: TTS init failure paths; successful audio generation writes file; export combines N clips with expected duration (tolerance).
- Manual: Model path selection, playback, export to Downloads, handling missing audio.

## Open Questions
- Do we need AIFF export in addition to M4A and WAV?
- Do we need persistent project files now or in a later iteration?

## Remaining Work (Small, Ordered)
1. **Create distributable macOS app bundle**
  - Move from `swift run` executable flow to an `.app` packaging flow suitable for end users.
2. **Model validation UX**
  - Validate GGUF presence and Qwen repo configuration before init and show clear per-field errors.
3. **Progress UX improvements**
  - Add per-paragraph progress callbacks for TTS generation and clearer batch progress display.
4. **Model repo and cache UX**
  - Add explicit control over Hugging Face cache location and richer feedback when large Qwen repos are first downloaded.
5. **Project file format v1**
  - Add explicit project metadata/versioning around transcript JSON for long-term compatibility.
6. **Test pass and smoke scripts**
  - Add focused tests for transcript roundtrip, sequencing duration math, and engine init failures.
