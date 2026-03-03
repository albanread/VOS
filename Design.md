# VoiceOverStudio — Design Doc

## Purpose
Mac app (Apple Silicon, macOS 14+) for creating voice-overs locally. Users create paragraphs with text, pick a voice, set an output filename, generate and preview audio, and export a full sequence with configurable gaps. No Python dependency in the final app.

## Goals
- Local-only inference: TTS via Sherpa-ONNX VITS; LLM via llama.cpp (GGUF) for text polishing.
- Paragraph-centric workflow: track text, selected voice (multi-speaker), output file name, generation state, and produced audio path.
- Playback and sequencing: play individual paragraphs; export a stitched timeline with per-paragraph gaps.
- Simple configuration: user-provided paths to TTS (model + tokens) and LLM GGUF; Apple Silicon optimized.
- Mac-native UX: SwiftUI app, sandbox-friendly file access via NSOpenPanel/NSSavePanel as needed.

## Current Status (March 2026)
- Implemented with real native engines:
  - `llama.cpp` built via CMake and linked through local `LLamaC` module.
  - `sherpa-onnx` built via `build-swift-macos.sh` and linked through local `SherpaOnnxC` module.
- Implemented core features:
  - Per-paragraph text, voice, output filename, gap, and speed.
  - Per-paragraph generate/playback and “Generate All”.
  - Transcript save/load (JSON) with backward-compatible paragraph decoding.
  - Export full sequence to M4A or WAV with per-paragraph gaps.
  - Model path pickers for LLM GGUF, VITS ONNX, tokens, and espeak-ng data directory.
  - Paragraph duplicate and list reordering hooks.
- Remaining blockers are primarily packaging/polish, not core functionality.

## Non-Goals
- Cloud inference or online services.
- iOS/iPadOS builds.
- Python scripts or CLI tooling in the shipped app.

## Constraints and Assumptions
- Running on Apple Silicon; prefer mac-friendly model formats: GGUF for llama.cpp, ONNX for Sherpa-ONNX; use `provider: "coreml"` when stable, fall back to CPU for compatibility.
- Models are user-supplied and stored outside the app bundle; paths persisted via AppStorage/UserDefaults.
- Audio export uses AVFoundation; resulting file written to user-selected location (default Downloads).
- Sherpa-ONNX and llama.cpp are integrated as local native builds (CMake/static libs + C module targets), not remote SwiftPM packages.
- App should guide users to obtain models: provide in-app links/buttons in Settings to download recommended GGUF (LLM) and ONNX/token files (TTS), show sizes, and set paths after download/selection.

## Architecture Overview
- UI: SwiftUI (single-window macOS app) with split view: settings sidebar + paragraph list.
- ViewModel: `ProjectViewModel` manages paragraphs, engine initialization, generation, playback, sequencing/export, and status.
- Services:
  - `TTSService` wraps Sherpa-ONNX OfflineTts; handles model init and wav generation per paragraph.
  - `LLMService` wraps llama.cpp; used for optional text improvement.
- Audio pipeline: per-paragraph wav output (48 kHz, mono) to temp folder; export merges tracks with gaps via `AVMutableComposition` -> `.m4a` (AAC 48 kHz) with optional WAV export for lossless ingest.
- Persistence: paragraphs held in-memory for now; optional future Project file (JSON) for saving/restoring sessions.
 - Persistence: paragraphs held in-memory for now; add save/load of "transcripts" (project JSON) to restore paragraphs, voice selections, gaps, and audio filenames; support re-generation when audio is missing.

## Data Model
- `Paragraph` (Identifiable, Codable)
  - `id: UUID`
  - `text: String`
  - `voiceId: String` (speaker/model selector; mapped to `sid` for multi-speaker VITS)
  - `gapDuration: Double` (seconds of silence after paragraph)
  - `audioPath: String?` (generated wav path)
  - `isGenerating: Bool` (UI state)
- Potential `Project` (future): name, outputDir, paragraphs, createdAt/updatedAt.

## User Flows
1) Configure models: user sets paths for LLM GGUF and TTS (model + tokens); click “Initialize Engines”.
2) Add/edit paragraphs: enter text, set voice (dropdown mapping to speaker ID), adjust gap, set output filename (auto default `para_<uuid>.wav`).
3) Optional: Improve text via LLM (local inference) per paragraph.
4) Generate audio: per paragraph, uses TTS; shows progress; stores `audioPath`; status updates.
5) Preview: play paragraph audio inline.
6) Export sequence: merge generated clips in order with gaps; write `.m4a` to chosen location; show completion status.
7) Model fetch/update: from Settings, user clicks “Get LLM model” or “Get TTS model/tokens”; app downloads to a chosen folder (or opens source URL), writes paths back into settings, and validates file presence before init.

## UI Layout (SwiftUI)
- Sidebar: app title, fields for model paths, Initialize button, Export button, status indicator.
- Main pane: list of `ParagraphRow`s with text editor, voice picker, gap field, improve/generate/play buttons, readiness badge.
- Toolbar: add/delete paragraph controls.

## Integration Details
- TTS: Sherpa-ONNX VITS config (ONNX models), allow `numThreads` tweak; consider optional `provider: "coreml"` flag when available; map `voiceId` -> speaker `sid` for multi-speaker models.
- LLM: llama.cpp bindings; load GGUF (Apple Silicon optimized); context size ~2048; non-streaming improveText helper; ensure cleanup on deinit.
- Model acquisition UX: Settings panel provides download buttons/links for recommended GGUF and ONNX+tokens, shows file sizes, writes chosen paths, and re-validates existence before initialization.
- File IO: save paragraph wav to `FileManager.default.temporaryDirectory` or user-selected output dir; on export prompt for destination if missing permissions.
- Audio join: `AVMutableComposition` + `insertEmptyTimeRange` for gaps; export via `AVAssetExportSession` to `.m4a` (AAC 48 kHz mono). Offer WAV 48 kHz export as an option for NLEs that prefer lossless ingest.

## Persistence Plan
- Short term: AppStorage for model paths; paragraphs live in-memory.
- Near term: add transcript save/load (Project JSON via FileDocument) storing paragraph order, text, voiceId, gap, chosen output filename, and existing audio paths; on load, if audio is missing, allow re-generate.
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
  - Validate selected files/directories before init and show clear per-field errors.
3. **Progress UX improvements**
  - Add per-paragraph progress callbacks for TTS generation and clearer batch progress display.
4. **CoreML provider toggle for TTS**
  - Add user-selectable `provider` (`cpu`/`coreml`) with fallback behavior and warnings.
5. **Project file format v1**
  - Add explicit project metadata/versioning around transcript JSON for long-term compatibility.
6. **Test pass and smoke scripts**
  - Add focused tests for transcript roundtrip, sequencing duration math, and engine init failures.
