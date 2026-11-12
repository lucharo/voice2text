// Shape-and-location gesture decoding after Kristensson & Zhai's SHARK2 (UIST 2004), with the pruning and
// the two standard deviations of FlorisBoard's StatisticalGlideTypingClassifier (Apache-2.0, fe1241f;
// see ios/THIRD_PARTY_NOTICES.md), itself after Étienne Desticourt's write-up in AnySoftKeyboard PR #1870.
import CoreGraphics
import Foundation

/// Turns a one-finger trace across the letter keys into ranked words.
///
/// Every candidate word has an "ideal" trace through its letters' key centres. A candidate is scored on
/// two channels: the shape distance between the two traces after scaling both into a unit box, and the
/// location distance between them on the keyboard. Each distance has a Gaussian likelihood, and the word's
/// frequency (and, when given, the previous word) supplies the prior. Candidates are pruned first to words
/// that start near the trace's first point and end near its last, then to those whose ideal trace length is
/// close to the trace's.
public final class SwipeDecoder: @unchecked Sendable {
  public static let samples = 64
  /// FlorisBoard's 22.08 is for a sum over 200 samples; the sum scales with the sample count.
  static let shapeStd: Double = 22.08 * Double(samples) / 200
  /// In key radii (the smaller key side), as FlorisBoard.
  public var locationStd: Double = 0.5109
  /// Fingers start and stop on the first and last letters more precisely than they pass the middle ones
  /// (SHARK2's observation), so the end points get their own channel, in key radii.
  public var endpointStd: Double = 0.6
  /// Ideal and actual trace lengths may differ by this many key radii.
  static let lengthThreshold: Double = 8.42
  /// Nats of prior between the rarest suggestible word and the commonest. AOSP's 0-255 frequency is
  /// already logarithmic, so it enters linearly. A stronger prior (10, 15, 20) measured worse on
  /// QualityEval's everyday words, not better: the AOSP counts come from encyclopedic text, so they
  /// under-rate chat words ("hey" 135 against "get" 160) and over-rate "the" against "there" and "time".
  public var frequencyWeight: Double = 5
  /// A swipe is drawn in lowercase: a capitalised entry (a name) is less likely meant, an all-capitals one
  /// (an acronym: "GRU" for "hey") much less. Tuned on QualityEval.
  public var properNounPenalty: Double = 2
  public var acronymPenalty: Double = 4

  public let lexicon: Lexicon
  public let layout: KeyboardLayout
  private let centers: [Character: CGPoint]
  private let radius: Double
  /// Lexicon entries bucketed by (first folded letter, last folded letter): 26 x 26 buckets.
  private var buckets: [[Int32]]

  public init(lexicon: Lexicon, layout: KeyboardLayout) {
    self.lexicon = lexicon
    self.layout = layout
    var centers: [Character: CGPoint] = [:]
    for k in layout.keys {
      if case .character(let c) = k.action, c.count == 1, let ch = c.first, ch.isLetter { centers[ch] = k.center }
    }
    self.centers = centers
    self.radius = Double(min(layout.unitWidth, layout.metrics.keyHeight))
    var b = [[Int32]](repeating: [], count: 26 * 26)
    for i in 0..<lexicon.count where lexicon.frequency(i) > 0 {
      let (f, l, n) = lexicon.withKey(i) { k in (k.first ?? 0, k.last ?? 0, k.count) }
      guard n >= 2, (97...122).contains(f), (97...122).contains(l) else { continue }
      b[Int(f - 97) * 26 + Int(l - 97)].append(Int32(i))
    }
    self.buckets = b
  }

  public struct Candidate: Equatable, Sendable {
    public let word: String
    public let score: Double
  }

  /// Ranked words for a trace in keyboard coordinates, best first. `bonus` adds nats to entries the context
  /// makes likelier (the words that often follow the previous one).
  public func decode(_ trace: [CGPoint], limit: Int = 5, bonus: [Int: Double] = [:]) -> [Candidate] {
    guard trace.count >= 2 else { return [] }
    let user = Self.resample(trace, Self.samples)
    let userNorm = Self.normalise(user)
    let userLength = Self.length(trace)
    let starts = nearestLetters(to: trace[0], 2), ends = nearestLetters(to: trace[trace.count - 1], 2)
    var best: [Candidate] = []
    let keep = limit * 2  // room for case variants ("us", "US") collapsed below
    for s in starts {
      for e in ends {
        for id in buckets[Int(s - 97) * 26 + Int(e - 97)] {
          let i = Int(id)
          let word = lexicon.word(i)
          guard let ideal = idealPoints(word), abs(Self.length(ideal) - userLength) < Self.lengthThreshold * radius else { continue }
          let resampled = Self.resample(ideal, Self.samples)
          let shape = Self.shapeDistance(Self.normalise(resampled), userNorm)
          let location = Self.locationDistance(resampled, user)
          // log Gaussian likelihoods (the shared constants drop out of the ranking)
          let lShape = -0.5 * pow(shape / Self.shapeStd, 2)
          let lLoc = -0.5 * pow(location / (locationStd * radius), 2)
          let dStart = Double(hypot(ideal[0].x - trace[0].x, ideal[0].y - trace[0].y))
          let dEnd = Double(hypot(ideal[ideal.count - 1].x - trace[trace.count - 1].x, ideal[ideal.count - 1].y - trace[trace.count - 1].y))
          let lEnds = -0.5 * (pow(dStart / (endpointStd * radius), 2) + pow(dEnd / (endpointStd * radius), 2))
          let lFreq = frequencyWeight * (Double(lexicon.frequency(i)) / 255 - 1)
          let score = lShape + lLoc + lEnds + lFreq - casePenalty(word) + (bonus[i] ?? 0)
          if best.count < keep || score > best[best.count - 1].score {
            let at = best.firstIndex { $0.score < score } ?? best.count
            best.insert(Candidate(word: word, score: score), at: at)
            if best.count > keep { best.removeLast() }
          }
        }
      }
    }
    var seen = Set<String>()
    return Array(best.filter { seen.insert($0.word.lowercased()).inserted }.prefix(limit))
  }

  func casePenalty(_ word: String) -> Double {
    switch EntryCase(word) {
    case .lower: 0
    case .name: properNounPenalty
    case .acronym: acronymPenalty
    }
  }

  /// The ideal trace through a word's keys, with repeated letters collapsed. Letters with no key of their own
  /// (é on the English layout) use their base letter's key.
  func idealPoints(_ word: String) -> [CGPoint]? {
    var pts: [CGPoint] = []
    for ch in word.lowercased() {
      let p = centers[ch] ?? String(ch).decomposedStringWithCanonicalMapping.unicodeScalars.first.flatMap { centers[Character($0)] }
      guard let p else {
        if ch == "'" || ch == "-" { continue }
        return nil
      }
      if pts.last != p { pts.append(p) }
    }
    return pts.count >= 1 ? pts : nil
  }

  func nearestLetters(to p: CGPoint, _ n: Int) -> [UInt8] {
    var d: [(UInt8, CGFloat)] = []
    for (ch, c) in centers {
      guard let b = Lexicon.fold(String(ch)).first else { continue }
      d.append((b, hypot(c.x - p.x, c.y - p.y)))
    }
    d.sort { $0.1 < $1.1 }
    var out: [UInt8] = []
    for (b, _) in d where !out.contains(b) {
      out.append(b)
      if out.count == n { break }
    }
    return out
  }

  // MARK: geometry

  static func length(_ pts: [CGPoint]) -> Double {
    var l = 0.0
    for i in 1..<max(1, pts.count) { l += Double(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
    return l
  }

  /// `n` points evenly spaced along the polyline.
  static func resample(_ pts: [CGPoint], _ n: Int) -> [CGPoint] {
    let total = length(pts)
    guard pts.count > 1, total > 0 else { return Array(repeating: pts[0], count: n) }
    let step = total / Double(n - 1)
    var out = [pts[0]]
    out.reserveCapacity(n)
    var carried = 0.0
    for i in 1..<pts.count {
      let a = pts[i - 1], b = pts[i]
      let seg = Double(hypot(b.x - a.x, b.y - a.y))
      guard seg > 0 else { continue }
      var t = step - carried
      while t <= seg + 1e-9, out.count < n {
        let f = CGFloat(t / seg)
        out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        t += step
      }
      carried = seg - (t - step)
    }
    while out.count < n { out.append(pts[pts.count - 1]) }
    return out
  }

  /// Scales into a box whose longest side is 1, centred on the origin.
  static func normalise(_ pts: [CGPoint]) -> [CGPoint] {
    var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
    for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
    let side = max(maxX - minX, maxY - minY, 0.00001)
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    return pts.map { CGPoint(x: ($0.x - cx) / side, y: ($0.y - cy) / side) }
  }

  /// Sum of point-to-point distances between two normalised traces.
  static func shapeDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
    var d = 0.0
    for i in 0..<min(a.count, b.count) { d += Double(hypot(a[i].x - b[i].x, a[i].y - b[i].y)) }
    return d
  }

  /// Mean half-L1 distance between two traces in points.
  static func locationDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
    var d = 0.0
    for i in 0..<min(a.count, b.count) { d += Double(abs(a[i].x - b[i].x) + abs(a[i].y - b[i].y)) }
    return d / Double(a.count) / 2
  }
}

/// One decoder per suggestion language, merged into the words a swipe types and offers.
public struct MultiSwipeDecoder: Sendable {
  public let decoders: [SwipeDecoder]
  public var languagePrior = LanguagePrior()
  /// Nats per nat of bigram lift: how much the previous word can promote the words that often follow it.
  /// 1 is the lift taken at face value; on QualityEval it beat 0.5 on Spanish sentences, and 2 on both.
  public var bigramWeight: Double = 1
  /// Alternatives scoring more than this many nats below the best word are not offered. On QualityEval, 4
  /// dropped junk alternatives (38% to 30%) without losing a single intended word from the bar.
  public var alternativeMargin: Double = 4
  public init(_ decoders: [SwipeDecoder]) { self.decoders = decoders }

  /// Ranked words for a trace, best first, one spelling per word. `context` is the text before the cursor.
  /// Each language's words carry that language's prior, so a Spanish word does not take an English swipe
  /// unless the sentence is Spanish, and the words that often follow the previous one are promoted.
  public func decode(_ trace: [CGPoint], context: String = "", limit: Int = 4) -> [String] {
    decodeScored(trace, context: context, limit: limit).map(\.word)
  }

  /// `decode`'s words with their scores (nats, higher is better), for the keyboard's debug log.
  public func decodeScored(_ trace: [CGPoint], context: String = "", limit: Int = 4) -> [SwipeDecoder.Candidate] {
    decodeScored(trace, context: TypingContext(before: context), limit: limit)
  }

  /// The same with the words before the swipe as the keyboard reads them: `TypingEngine.context`, which leaves out
  /// a word still being typed (the swipe ends it, so it is not yet a word the swipe follows) and keeps a swiped
  /// word, which has no space after it until the next word starts. A typing log had "E" left from a mistyped word
  /// when a swipe for "leaving" began: read as the word before, it made Spanish the likelier language, every
  /// English word paid `LanguagePrior.cap`, and the Spanish "kirchhoff" won.
  public func decodeScored(_ trace: [CGPoint], context ctx: TypingContext, limit: Int = 4) -> [SwipeDecoder.Candidate] {
    let priors = languagePrior.priors(decoders.map(\.lexicon), primary: decoders.first?.layout.language.rawValue, context: ctx)
    let merged = zip(decoders, priors).flatMap { d, p in
      let bonus = ctx.followerBonus(in: d.lexicon, weight: bigramWeight)
      return d.decode(trace, limit: limit, bonus: bonus).map { SwipeDecoder.Candidate(word: $0.word, score: $0.score + p) }
    }.sorted { $0.score > $1.score }
    // alternatives far behind the best are noise ("gift", "fount", "glint" under "going"): leave them out
    let floor = (merged.first?.score ?? 0) - alternativeMargin
    var seen = Set<String>()
    return Array(merged.filter { $0.score >= floor && seen.insert($0.word.lowercased()).inserted }.prefix(limit))
  }
}
