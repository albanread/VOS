# VoiceOverStudio

I dont know about you, but I spend more time recording speech voice overs, than I do recording my actual videos, and I dont enjoy the sound of my own voice, this application allows you to script a 'voice over' for your videos.

Local-only macOS app for Apple Silicon that writes and produces voice-over tracks with on-device models. Text polishing uses llama.cpp, while speech generation now runs through a native Swift + MLX Qwen3-TTS pipeline.

Thanks to Qwen3 - this version sounds more human than many speech synthesizers, downsides are that this does require a lot of memory, 16GB seems like a mininum to me, and more is especially useful if you are going to use the reference voice recording.

Like many A.I. features this is very non-deterministic,  meaning that voices drift significantly in tone and character.

## What it does
- Paragraph-centric editor with per-paragraph text, voice preset, speed, gap, and output filename.
- Local inference only: llama.cpp GGUF for Improve/Rephrase and `mlx-audio-swift` + `mlx-swift` for Qwen3-TTS speech generation.
- Audio workflow: per-paragraph WAV generation, inline preview, and stitched export to M4A or WAV.
- Guided setup: compute-tier presets choose recommended GGUF and Qwen model repos, with managed downloads under `~/Library/vos2026`.
- Project IO: save/load transcript JSON and re-generate missing paragraph audio.

## Runtime architecture
- **LLM**: local llama.cpp static libraries linked through the `LLamaC` target.
- **TTS**: native Swift MLX runtime via `mlx-audio-swift` (`MLXAudioCore`, `MLXAudioTTS`) plus `MLX` from `mlx-swift`, loading Qwen3-TTS model repos from Hugging Face.
- **Voice selection**: app-defined prompt presets such as `narrator_clear`, `narrator_warm`, and `documentary`, rather than numeric speaker IDs.
- **Audio pipeline**: generated WAVs are stored per paragraph, previewed locally, and merged with configured gaps for final export.

## Voice backend change
- Voice generation no longer uses Apple TTS or Sherpa/ONNX voices.
- The app now standardizes on Qwen3-TTS models running locally through Swift MLX libraries.
- Existing text-polish features still use llama.cpp, so both the MLX Qwen stack and local llama.cpp static libraries are required for a full build.

## Requirements
- macOS 15+ on Apple Silicon
- Xcode 15+ and Command Line Tools
- Xcode Metal tools available through `xcrun` (`metal` and `metallib`)
- CMake 3.28+ (`brew install cmake`)
- Git submodules checked out (`git submodule update --init --recursive`)

Metal 3.2 requires `macOS 15.0+`, so older Apple Silicon Macs running macOS 14 are no longer supported by this build.

## Build from scratch
Run these steps from the repository root.

### 1. Resolve Swift packages

```bash
swift package resolve
```

### 2. Build the bundled MLX Metal library

The app bundles MLX Metal kernels as `Sources/VoiceOverStudio/Resources/default.metallib`.

```bash
./Scripts/build-mlx-metallib.sh
```

### 3. Build llama.cpp static libraries

The app still links to a local llama.cpp build for text assistance.

```bash
git submodule update --init --recursive
cmake -S ThirdParty/llama.cpp -B ThirdParty/llama.cpp/build \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
	-DBUILD_SHARED_LIBS=OFF \
	-DLLAMA_BUILD_TESTS=OFF \
	-DLLAMA_BUILD_EXAMPLES=OFF \
	-DLLAMA_BUILD_SERVER=OFF \
	-DGGML_METAL=ON
cmake --build ThirdParty/llama.cpp/build --config Release
```

Current upstream output layout places the needed archives under `build/src` and `build/ggml/src`; the package manifest is already wired for that layout.

### 4. Build and run the app

```bash
swift build
swift run VoiceOverStudio
```

If you use the VS Code workspace task, run **Run VoiceOverStudio** after the steps above.

### 5. Build a local `.app` bundle

For microphone permission prompts and a more realistic macOS app launch flow, build the local app bundle instead of using `swift run`.

```bash
./Scripts/build-app-bundle.sh
open Build/debug/VoiceOverStudio.app
```

The bundle includes an `Info.plist` with `NSMicrophoneUsageDescription`, which makes reference-voice recording behave like a normal macOS app.

## Quick rebuild

Once setup is done, the normal inner loop is:

```bash
swift build
swift run VoiceOverStudio
```

Use `./Scripts/build-app-bundle.sh` when you need to test microphone permissions or app-bundle behavior.

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
- If `Bundle.module` build errors mention a missing `default.metallib`, rerun `./Scripts/build-mlx-metallib.sh` and then `swift build`.
- If `xcrun metal` or `xcrun metallib` is missing, open Xcode once and make sure the full Xcode app is selected with `xcode-select -p`.
- If the app fails to link, rebuild llama.cpp so `ThirdParty/llama.cpp/build` contains the static archives expected by `Package.swift`.
- If TTS initialization fails, verify the configured Hugging Face repo exists and that the machine has enough unified memory for the selected Qwen model tier.
- The current `mlx-audio-swift` dependency emits README resource warnings during `swift build`; they are upstream package warnings and do not block the app build.
