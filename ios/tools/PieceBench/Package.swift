// swift-tools-version: 6.2
// piece-bench: the iPhone app's two ways of transcribing a dictation, compared on the Mac with the phone's
// FluidAudio and models: whole-file after Stop (the app up to build 3) and in pieces while recording
// (V2TPieces, #112). See main.swift.
import PackageDescription

let package = Package(
  name: "PieceBench",
  platforms: [.macOS("15.0")],
  dependencies: [
    // the revision ios/project.yml pins; no traits: ASR only
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "55f65d9c887244a93c45f18225a35b3533516446", traits: []),
    .package(path: "../../Packages/V2TKeyboardCore"),
  ],
  targets: [
    .executableTarget(
      name: "piece-bench",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "V2TPieces", package: "V2TKeyboardCore"),
      ],
      path: "Sources"
    )
  ]
)
