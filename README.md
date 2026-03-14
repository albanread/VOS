# VoiceOverStudio

Local-only macOS app for Apple Silicon that writes and produces voice-over tracks with on-device models. Text polishing stays on llama.cpp, while speech generation now runs through Qwen3-TTS on MLX.

## What it does
- Paragraph-centric editor with per-paragraph text, voice preset, speed, gap, and output filename.
- Local inference only: llama.cpp GGUF for Improve/Rephrase and MLX Qwen3-TTS for speech generation.
- Audio workflow: per-paragraph WAV generation, inline preview, and stitched export to M4A or WAV.
- Guided setup: compute-tier presets choose recommended GGUF and Qwen model repos, with managed downloads under `~/Library/vos2026`.
- Project IO: save/load transcript JSON and re-generate missing paragraph audio.

## Runtime architecture
- **LLM**: local llama.cpp static libraries linked through the `LLamaC` target.
- **TTS**: `mlx-audio-swift` (`MLXAudioCore`, `MLXAudioTTS`) plus `MLX` from `mlx-swift`, loading Qwen3-TTS model repos from Hugging Face.
- **Voice selection**: app-defined prompt presets such as `narrator_clear`, `narrator_warm`, and `documentary`, rather than numeric speaker IDs.
- **Audio pipeline**: generated WAVs are stored per paragraph, previewed locally, and merged with configured gaps for final export.

## Requirements
- macOS 14+ on Apple Silicon
- Xcode 15+ and Command Line Tools
- CMake 3.28+ (`brew install cmake`)
- Git submodules checked out (`git submodule update --init --recursive`)

## Build llama.cpp
The app still links to a local llama.cpp build for text assistance.

```bash
cd VoiceOverStudio/ThirdParty/llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DGGML_METAL=ON
cmake --build build --config Release
```

Current upstream output layout places the needed archives under `build/src` and `build/ggml/src`; the package manifest is already wired for that layout.

## Build and run
```bash
cd VoiceOverStudio
swift build
swift run VoiceOverStudio
```

The root `run.sh` launcher remains available if you prefer using the repo wrapper.

## Using the app
1. Launch `VoiceOverStudio`.
2. In Settings, choose the computer tier and run **1-Click Auto Setup**, or point the app at an existing GGUF and Qwen repo.
3. Add paragraphs, choose Qwen voice presets, and adjust speed or gaps.
4. Optionally run **Improve** or **Rephrase** with the local LLM.
5. Generate paragraph audio, preview it, then export the final sequence.

## Models
- Default LLM downloads live under `~/Library/vos2026/llm`.
- The default TTS repo is `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`, with larger Qwen recommendations selected on bigger machines.
- Advanced settings can override the LLM URL and the Qwen model repo string.

## Troubleshooting
- If the app fails to link, rebuild llama.cpp so `ThirdParty/llama.cpp/build` contains the static archives expected by `Package.swift`.
- If TTS initialization fails, verify the configured Hugging Face repo exists and that the machine has enough unified memory for the selected Qwen model tier.
- The current `mlx-audio-swift` dependency emits README resource warnings during `swift build`; they are upstream package warnings and do not block the app build.
