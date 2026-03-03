# VoiceOverStudio

Local-only macOS app (Apple Silicon, macOS 14+) for producing voice-overs. Enter paragraphs, pick voices, locally polish text with an LLM, synthesize audio with Sherpa-ONNX VITS, and export a stitched sequence with gaps—no cloud calls.

## What it does
- Paragraph-centric editor: text, voice, per-paragraph gap, output filename, duplicate/remove, drag ordering hooks.
- Local inference: llama.cpp GGUF for text improvement; Sherpa-ONNX VITS for TTS (multi-speaker, sid-based voices).
- Audio flow: per-paragraph WAVs -> preview playback -> export full sequence (gaps honored) to M4A or WAV via AVFoundation.
- Model helper: one-click download/setup with compute-tier presets; manual URL overrides; paths persisted under `~/Library/vos2026`.
- Project IO: save/load transcripts (JSON) and re-generate missing audio; hotkeys for Save/Load/Export.

## How it works
- **LLM**: llama.cpp static lib via the local `LLamaC` target. Loads a user-provided GGUF (default 1B/3B/8B recommendations) and runs short edits for “Improve” and “Rephrase”.
- **TTS**: Sherpa-ONNX OfflineTts via the `SherpaOnnxC` target. Expects a VITS ONNX + `tokens.txt` plus either `espeak-ng-data` or `lexicon.txt`; voice metadata seeded from VCTK package when present.
- **Audio pipeline**: generates mono WAVs (48 kHz), keeps paths per paragraph, merges with `AVMutableComposition` and optional silence ranges, exports `.m4a` (AAC) or `.wav`.
- **Model management**: default model root `~/Library/vos2026` with `llm/`, `tts/`, `downloads/`. Auto-setup downloads the recommended GGUF and VITS package, extracts, and rewires paths.

## Requirements
- macOS 14+ on Apple Silicon
- Xcode 15+ (Swift 5.9 toolchain) and Command Line Tools
- CMake 3.28+ (`brew install cmake`)
- Git submodules checked out (`git submodule update --init --recursive`)

## Build third-party libs
These must be built once to produce the static libs the Swift targets link against.

1) **llama.cpp (metal, static)**
```bash
cd VoiceOverStudio/ThirdParty/llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DGGML_METAL=ON
cmake --build build --config Release
# Produces build/bin/libllama.a and headers used by Sources/LLamaC
```

2) **sherpa-onnx (C API, static)**
```bash
cd VoiceOverStudio/ThirdParty/sherpa-onnx
./build-swift-macos.sh
# Produces build-swift-macos/install/lib/libsherpa-onnx.a and headers
```

## Build & run
```bash
cd VoiceOverStudio
swift run VoiceOverStudio        # debug run
# or: swift build -c release
```
A convenience launcher is available from repo root: `./run.sh`.

## Using the app
1) Launch `VoiceOverStudio` (via `swift run` or the built app).
2) In Settings (sidebar): choose Computer Tier, then click **1-Click Auto Setup** to download and wire models, or set paths manually.
3) Add paragraphs, pick voices, set gaps/output names.
4) Optional: **Improve** (TTS-safe expansions) or **Rephrase** (spoken clarity) per paragraph.
5) Generate audio per paragraph or **Generate All**; preview with Play.
6) Export the full sequence (M4A or WAV). Save/Load transcript to persist the project layout.

## Models
- Defaults download to `~/Library/vos2026`: `llm/Llama-3.2-1B-Instruct-Q4_K_M.gguf` (or tier-based alternative) and `tts/vits-vctk/...` containing `model.onnx`, `tokens.txt`, `lexicon.txt`, `espeak-ng-data/`.
- Manual override URLs are available in Settings → Advanced. Provide any GGUF for the LLM and any Sherpa-ONNX-supported VITS package for TTS.

## Troubleshooting
- If engines do not initialize: verify files exist at the paths shown in Settings and that `espeak-ng-data` or `lexicon.txt` accompanies the ONNX model.
- Re-run `./build-swift-macos.sh` after pulling sherpa-onnx updates; re-run the llama.cpp CMake build after updating that submodule.
