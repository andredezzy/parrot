// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Pinned past v1.0.0 for argmaxinc/argmax-oss-swift#514: before it, any
        // transcription with promptTokens came back empty, because a prediction
        // made while forcing the prompt was allowed to complete the segment.
        // Move to a version requirement once a release carries it.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git",
                 revision: "97d09fd9790393579d2834e2bc098deb3e26bc06"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        // whisper.cpp, built once as a static archive and checked in. It has no SPM
        // manifest of its own, and the community one disables Metal because the
        // maintainer could not get ggml-metal.m through SwiftPM — Metal being the
        // reason to reach for whisper.cpp at all. Built here with
        // GGML_METAL_EMBED_LIBRARY, so the shader lives inside the archive and there
        // is no .metallib to ship beside the binary.
        //
        // Rebuild with Vendor/whispercpp/rebuild.sh, which records the upstream
        // commit it came from.
        .systemLibrary(name: "whispercpp", path: "Vendor/whispercpp/include"),
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "whispercpp",
            ],
            linkerSettings: [
                .unsafeFlags(["-LVendor/whispercpp/lib"]),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
