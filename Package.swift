// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let llamaBuildPath = packageRoot + "/ThirdParty/llama.cpp/build"
let llamaLibrarySearchPaths = [
    llamaBuildPath + "/src",
    llamaBuildPath + "/ggml/src",
    llamaBuildPath + "/ggml/src/ggml-blas",
    llamaBuildPath + "/ggml/src/ggml-metal",
]

let package = Package(
    name: "VoiceOverStudio",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(
            name: "VoiceOverStudio",
            targets: ["VoiceOverStudio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
    ],
    targets: [
        .executableTarget(
            name: "VoiceOverStudio",
            dependencies: [
                .target(name: "LLamaC"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/VoiceOverStudio",
            resources: [
                .copy("Resources/default.metallib")
            ]
        ),
        .target(
            name: "LLamaC",
            path: "Sources/LLamaC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("m"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .unsafeFlags([
                    "-L\(llamaLibrarySearchPaths[0])",
                    "-L\(llamaLibrarySearchPaths[1])",
                    "-L\(llamaLibrarySearchPaths[2])",
                    "-L\(llamaLibrarySearchPaths[3])",
                    "-lllama",
                    "-lggml",
                    "-lggml-cpu",
                    "-lggml-blas",
                    "-lggml-metal",
                    "-lggml-base",
                ], .when(platforms: [.macOS]))
            ]
        ),
    ]
)
