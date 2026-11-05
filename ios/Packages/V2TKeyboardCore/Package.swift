// swift-tools-version: 6.0
// The keyboard's engines with no UIKit: layouts, lexicon, tap correction, swipe decoding, prediction and the
// typing state machine. Tested on the Mac with `swift test`; linked by the keyboard extension and the app.
import PackageDescription

let package = Package(
  name: "V2TKeyboardCore",
  platforms: [.iOS("26.0"), .macOS("15.0")],
  products: [
    .library(name: "V2TKeyboardCore", targets: ["V2TKeyboardCore"]),
    .library(name: "V2TCleanup", targets: ["V2TCleanup"]),
    .library(name: "V2TPieces", targets: ["V2TPieces"]),
  ],
  targets: [
    .target(name: "V2TKeyboardCore"),
    .testTarget(name: "V2TKeyboardCoreTests", dependencies: ["V2TKeyboardCore"]),
    // The dictation-cleanup prompt and casual-mode word guard, ported from v2t/backends.py; standard library only.
    .target(name: "V2TCleanup"),
    .testTarget(name: "V2TCleanupTests", dependencies: ["V2TCleanup"], resources: [.copy("golden.json")]),
    // Dictation transcribed in pieces while it is recorded (#112), the Mac's PieceDecoder rule; no model code.
    .target(name: "V2TPieces"),
    .testTarget(name: "V2TPiecesTests", dependencies: ["V2TPieces"]),
  ]
)
