// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaStub",
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        .target(
            name: "llama",
            path: "Sources"
        )
    ]
)
