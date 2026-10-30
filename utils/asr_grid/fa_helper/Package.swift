// swift-tools-version: 6.2
// A long-lived FluidAudio process for grid.py's `fluidaudio` runtime: Core ML models
// FluidAudio runs that have no Python or MLX route (Nemotron Unified), plus FluidAudio's
// own Parakeet v3 so a timing race runs both in one process. See main.swift.
import PackageDescription

let package = Package(
    name: "fa-helper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 55f65d9 = FluidInference/FluidAudio#1071, Nemotron Unified on the Unified managers.
        // No traits: ASR only (drops TTS, diarization and the text-normalisation binary).
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "55f65d9c887244a93c45f18225a35b3533516446",
            traits: []
        )
    ],
    targets: [
        .executableTarget(
            name: "fa-helper",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources"
        )
    ]
)
