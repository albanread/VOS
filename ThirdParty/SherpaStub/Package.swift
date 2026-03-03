// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SherpaStub",
    products: [
        .library(name: "sherpa-onnx", targets: ["SherpaOnnx"])
    ],
    targets: [
        .target(name: "SherpaOnnx", path: "Sources")
    ]
)
