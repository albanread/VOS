// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let sherpaLibPath = "ThirdParty/sherpa-onnx/build-swift-macos/install/lib"
let llamaLibPath  = "ThirdParty/llama.cpp/build/bin"

let package = Package(
    name: "VoiceOverStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "VoiceOverStudio",
            targets: ["VoiceOverStudio"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "VoiceOverStudio",
            dependencies: [
                .target(name: "LLamaC"),
                .target(name: "SherpaOnnxC"),
            ],
            path: "Sources/VoiceOverStudio"
        ),
        .target(
            name: "LLamaC",
            path: "Sources/LLamaC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("pthread"),
                .linkedLibrary("m"),
                .unsafeFlags([
                    "-L/Volumes/xb/voiceover/VoiceOverStudio/\(llamaLibPath)",
                    "-lllama",
                    "-Xlinker", "-rpath", "-Xlinker",
                    "/Volumes/xb/voiceover/VoiceOverStudio/\(llamaLibPath)",
                ], .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "SherpaOnnxC",
            path: "Sources/SherpaOnnxC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-L/Volumes/xb/voiceover/VoiceOverStudio/\(sherpaLibPath)",
                    "-lsherpa-onnx",
                    "-lonnxruntime",
                ], .when(platforms: [.macOS])),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
