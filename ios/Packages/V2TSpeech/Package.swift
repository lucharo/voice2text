// swift-tools-version: 6.0
// The app's on-device speech engine: which model a device gets, where its files live, downloading and loading it,
// and 16 kHz mono samples to text, through FluidAudio on the Neural Engine. No UIKit. Linked by the v2t app; other
// apps depend on it through the repository's root Package.swift. Tested on the Mac with `swift test`.
import PackageDescription

let package = Package(
  name: "V2TSpeech",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "V2TSpeech", targets: ["V2TSpeech"]),
  ],
  dependencies: [
    // 55f65d9: the revision the phone bench measured Nemotron Unified with (utils/phone_bench/project.yml). The
    // root Package.swift pins the same revision (ManifestTests checks).
    .package(url: "https://github.com/FluidInference/FluidAudio", revision: "55f65d9c887244a93c45f18225a35b3533516446"),
  ],
  targets: [
    .target(name: "V2TSpeech", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    .testTarget(name: "V2TSpeechTests", dependencies: ["V2TSpeech", .product(name: "FluidAudio", package: "FluidAudio")]),
  ]
)
