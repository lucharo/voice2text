// swift-tools-version: 6.0
// The keyboard's engines with no UIKit: layouts, lexicon, tap correction, swipe decoding, prediction and the
// typing state machine. Tested on the Mac with `swift test`; linked by the keyboard extension and the app.
import PackageDescription

let package = Package(
  name: "V2TKeyboardCore",
  platforms: [.iOS("26.0"), .macOS("15.0")],
  products: [.library(name: "V2TKeyboardCore", targets: ["V2TKeyboardCore"])],
  targets: [
    .target(name: "V2TKeyboardCore"),
    .testTarget(name: "V2TKeyboardCoreTests", dependencies: ["V2TKeyboardCore"]),
  ]
)
