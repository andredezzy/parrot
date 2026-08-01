// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Fork carries a two-line decoder fix: a prediction made while forcing
        // the prompt tokens must not complete the segment, or every prompted
        // transcription comes back empty. Upstream PR pending.
        .package(url: "https://github.com/andredezzy/argmax-oss-swift.git",
                 branch: "fix/prompt-prefill-completes-segment"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
