import CoreGraphics
import Foundation
@testable import V2TKeyboardCore

/// The real AOSP lexicons, built by `ios/tools/build_lexicons.py ios/build/lexicons` (ios/setup.sh runs it).
enum Fixtures {
  static let lexiconDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appending(path: "../../../../build/lexicons").standardized

  static func lexicon(_ lang: String) throws -> Lexicon {
    let url = lexiconDir.appending(path: "\(lang).v2tlex")
    guard FileManager.default.fileExists(atPath: url.path()) else {
      throw Lexicon.FormatError(description: "missing \(url.path()); run ios/tools/build_lexicons.py ios/build/lexicons")
    }
    return try Lexicon(contentsOf: url, language: lang)
  }

  static let english = Result { try lexicon("en") }
  static let spanish = Result { try lexicon("es") }
}

/// Deterministic noise for synthetic traces (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func gaussian() -> Double {
    let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12), u2 = Double.random(in: 0..<1, using: &self)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
  }
}

/// A finger-like trace through a word's keys: each key's centre jittered by `jitter` key widths, joined by
/// segments bowed by about `bow` of their length and sampled every 4 pt, as a touch screen reports them.
/// `jitter: 0` gives a clean trace through the key centres (no bow).
func syntheticTrace(_ word: String, layout: KeyboardLayout, jitter: Double, bow: Double = 0.08, rng: inout SeededRandom) -> [CGPoint]? {
  var centers: [Character: CGPoint] = [:]
  for k in layout.keys { if case .character(let c) = k.action, let ch = c.first, c.count == 1 { centers[ch] = k.center } }
  var anchors: [CGPoint] = []
  for ch in word.lowercased() {
    guard let c = centers[ch] ?? String(ch).decomposedStringWithCanonicalMapping.unicodeScalars.first.flatMap({ centers[Character($0)] }) else { return nil }
    let u = Double(layout.unitWidth)
    anchors.append(CGPoint(x: c.x + CGFloat(rng.gaussian() * jitter * u), y: c.y + CGFloat(rng.gaussian() * jitter * u)))
  }
  guard anchors.count >= 2 else { return nil }
  var out = [anchors[0]]
  for i in 1..<anchors.count {
    let a = anchors[i - 1], b = anchors[i]
    let len = hypot(b.x - a.x, b.y - a.y)
    let steps = max(1, Int(len / 4))
    let bow = jitter == 0 ? 0 : CGFloat(rng.gaussian() * bow) * len  // perpendicular bulge
    let nx = len > 0 ? -(b.y - a.y) / len : 0, ny = len > 0 ? (b.x - a.x) / len : 0
    for s in 1...steps {
      let t = CGFloat(s) / CGFloat(steps), arc = 4 * t * (1 - t) * bow
      out.append(CGPoint(x: a.x + (b.x - a.x) * t + nx * arc, y: a.y + (b.y - a.y) * t + ny * arc))
    }
  }
  return out
}
