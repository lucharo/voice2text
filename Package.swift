// swift-tools-version: 6.0
// Lets another iPhone app depend on v2t's speech engine by git URL; SwiftPM reads a manifest only at a repository's
// root. The package itself, with its tests, is ios/Packages/V2TSpeech, which the v2t app links by path. Depend on a
// revision or branch: the FluidAudio pin is a revision, which SwiftPM refuses under a version requirement.
import PackageDescription

let package = Package(
  name: "V2TSpeech",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "V2TSpeech", targets: ["V2TSpeech"]),
  ],
  dependencies: [
    // the same revision as ios/Packages/V2TSpeech/Package.swift (its ManifestTests checks)
    .package(url: "https://github.com/FluidInference/FluidAudio", revision: "55f65d9c887244a93c45f18225a35b3533516446"),
  ],
  targets: [
    .target(
      name: "V2TSpeech",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
      path: "ios/Packages/V2TSpeech/Sources/V2TSpeech"),
  ]
)
