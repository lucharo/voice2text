import CoreGraphics
import Foundation

/// One key press of the word being typed: the character the key produced and where the finger landed
/// (nil when it came from a long-press alternative or was read back from the document).
public struct TypedKey: Equatable, Sendable {
  public let character: Character
  public let point: CGPoint?
  public init(_ character: Character, at point: CGPoint? = nil) {
    self.character = character
    self.point = point
  }
}

public struct Suggestion: Equatable, Sendable {
  public enum Kind: Sendable { case typed, correction, completion, prediction }
  public let word: String
  public let kind: Kind
  public let score: Double
}

/// Spelling correction and completion for the word being typed.
///
/// A beam search walks the lexicons' sorted keys one typed letter at a time. Each touch can stand for the
/// key it hit or a neighbour, scored by a Gaussian over the distance from the touch to that key's centre;
/// an extra letter (a skipped touch) or a missed one (an inserted letter) costs a fixed penalty. Finished
/// words and completions then add a frequency prior. This is how a touch keyboard's spatial model works in
/// general; the constants are ours, tuned on tests/fixtures, not Apple's.
public final class Suggester: @unchecked Sendable {
  public var lexicons: [Lexicon]
  public let layout: KeyboardLayout
  /// Touch spread in key widths.
  public var touchStd: Double = 0.42
  public var editPenalty: Double = 5.0
  public var frequencyWeight: Double = 8.0
  /// Per letter a completion adds beyond what was typed.
  public var completionPenalty: Double = 0.4
  public var beamWidth = 48
  public var maxEdits = 2
  /// Typed in lowercase, a capitalised entry (a name: "Ford" for "doed") is less likely meant.
  public var properNounPenalty: Double = 2.0
  /// Nats a correction must beat the word as typed by before autocorrect applies it.
  public var autocorrectMargin: Double = 2.0

  private let centers: [CGPoint?]

  public init(lexicons: [Lexicon], layout: KeyboardLayout) {
    self.lexicons = lexicons
    self.layout = layout
    self.centers = layout.letterCenters
  }

  struct State {
    var lex: Int
    var range: Range<Int>
    var prefix: [UInt8]
    var cost: Double
    var edits: Int
  }

  /// Up to `limit` suggestions, best first: the typed word when it is a word, corrections and completions.
  public func suggestions(for typed: [TypedKey], limit: Int = 3) -> [Suggestion] {
    let literal = String(typed.map(\.character))
    let folded = Lexicon.fold(literal)
    guard !folded.isEmpty else { return [] }
    let states = search(typed)
    var scored: [String: Suggestion] = [:]
    let typedLower = literal == literal.lowercased()
    func offer(_ word: String, _ kind: Suggestion.Kind, _ raw: Double) {
      let score = typedLower && word.first?.isUppercase == true ? raw - properNounPenalty : raw
      let w = Self.applyCase(of: literal, to: word)
      if let old = scored[w.lowercased()], old.score >= score { return }
      scored[w.lowercased()] = Suggestion(word: w, kind: kind, score: score)
    }
    for s in states {
      let lex = lexicons[s.lex]
      // finished words: keys equal to the prefix
      var i = s.range.lowerBound
      while i < s.range.upperBound, lex.keyLength(i) == s.prefix.count {
        let f = lex.frequency(i)
        if f > 0 || lex.word(i).lowercased() == literal.lowercased() {
          let w = lex.word(i)
          let kind: Suggestion.Kind = w.lowercased() == literal.lowercased() ? .typed : .correction
          offer(w, kind, -s.cost + prior(f))
        }
        i += 1
      }
      // completions: the commonest longer words in the range
      if s.prefix.count >= 2 {
        for (j, f) in topFrequencies(lex, i..<s.range.upperBound, 3) {
          let extra = lex.keyLength(j) - s.prefix.count
          offer(lex.word(j), .completion, -s.cost + prior(f) - completionPenalty * Double(extra) - 0.5)
        }
      }
    }
    var out = scored.values.sorted { $0.score > $1.score }
    // the literal word keeps a slot even when it is not a word, so it can always be chosen as typed
    if !out.prefix(limit).contains(where: { $0.word.lowercased() == literal.lowercased() }) {
      out.insert(Suggestion(word: literal, kind: .typed, score: -.infinity), at: min(out.count, limit - 1))
    }
    return Array(out.prefix(limit))
  }

  /// The replacement autocorrect should apply when the word is finished, or nil to leave it as typed.
  public func autocorrection(for typed: [TypedKey], learned: Set<String> = []) -> String? {
    let literal = String(typed.map(\.character))
    let lower = literal.lowercased()
    guard Lexicon.fold(literal).count >= 1, !learned.contains(lower) else { return nil }
    if lower == "i", lexicons.contains(where: { $0.language == "en" }) { return "I" }
    guard typed.count >= 2 else { return nil }
    let key = Lexicon.fold(literal)
    for lex in lexicons where lex.exactRange(key).contains(where: { lex.word($0).lowercased() == lower }) {
      return nil  // a real word, as typed; a missing accent or apostrophe ("cancion", "dont") is corrected below
    }
    // look past the bar's three slots: completions may fill them, but only a correction autocorrects
    let all = suggestions(for: typed, limit: 10)
    guard let best = all.first(where: { $0.kind == .correction }) else { return nil }
    let typedScore = all.first { $0.kind == .typed }?.score ?? -.infinity
    return best.score - typedScore >= autocorrectMargin || typedScore == -.infinity ? best.word : nil
  }

  func prior(_ f: Int) -> Double { frequencyWeight * (Double(f) / 255 - 1) }

  func search(_ typed: [TypedKey]) -> [State] {
    var beam: [State] = lexicons.indices.map { State(lex: $0, range: 0..<lexicons[$0].count, prefix: [], cost: 0, edits: 0) }
    let u = Double(layout.unitWidth)
    let letters = typed.compactMap { t in Lexicon.fold(String(t.character)).first.map { (t, $0) } }  // apostrophes and hyphens are not in the keys
    // states that consumed the next letter already (a transposition), merged in at the next step
    var ahead: [State] = []
    for (n, (t, h)) in letters.enumerated() {
      let options = letterOptions(h, t.point, unit: u)
      var next: [State] = ahead
      ahead = []
      next.reserveCapacity(beam.count * (options.count + 2))
      for s in beam {
        let lex = lexicons[s.lex]
        for (c, cost) in options {
          let p = s.prefix + [c]
          let r = lex.prefixRange(p, in: s.range)
          if !r.isEmpty { next.append(State(lex: s.lex, range: r, prefix: p, cost: s.cost + cost, edits: s.edits)) }
        }
        guard s.edits < maxEdits else { continue }
        // this touch was a mistake: skip it
        next.append(State(lex: s.lex, range: s.range, prefix: s.prefix, cost: s.cost + editPenalty, edits: s.edits + 1))
        // two letters swapped ("becuase"): take the next one first, then this one
        if n + 1 < letters.count {
          let h2 = letters[n + 1].1
          let p = s.prefix + [h2, h]
          let r = lex.prefixRange(p, in: s.range)
          if h2 != h, !r.isEmpty { ahead.append(State(lex: s.lex, range: r, prefix: p, cost: s.cost + editPenalty * 0.8, edits: s.edits + 1)) }
        }
        // a letter was missed before this touch
        if s.prefix.count >= 1 {
          for x in UInt8(97)...UInt8(122) {
            let p = s.prefix + [x, h]
            let r = lex.prefixRange(p, in: s.range)
            // a doubled letter typed once ("helo", "tomorow") is the commonest miss, so it costs half
            let cost = x == s.prefix.last ? editPenalty * 0.5 : editPenalty
            if !r.isEmpty { next.append(State(lex: s.lex, range: r, prefix: p, cost: s.cost + cost, edits: s.edits + 1)) }
          }
        }
      }
      next.sort { $0.cost < $1.cost }
      // one state per (lexicon, prefix), the cheapest
      var seen = Set<[UInt8]>(), kept: [State] = []
      for s in next where kept.count < beamWidth {
        if seen.insert([UInt8(s.lex)] + s.prefix).inserted { kept.append(s) }
      }
      beam = kept
      if beam.isEmpty { break }
    }
    return beam
  }

  /// The letters a touch may have meant with their spatial costs: the hit key free, neighbours by distance.
  func letterOptions(_ hit: UInt8, _ point: CGPoint?, unit: Double) -> [(UInt8, Double)] {
    guard let p = point else { return [(hit, 0)] }
    var out: [(UInt8, Double)] = [(hit, 0)]
    let hd = centers[Int(hit)].map { Double(hypot($0.x - p.x, $0.y - p.y)) } ?? 0
    for b in UInt8(97)...UInt8(122) where b != hit {
      guard let c = centers[Int(b)] else { continue }
      let d = Double(hypot(c.x - p.x, c.y - p.y))
      guard d < 1.8 * unit else { continue }
      // relative to the hit key, so a touch on a key's edge makes its neighbour nearly as likely
      let cost = 0.5 * (pow(d / (touchStd * unit), 2) - pow(hd / (touchStd * unit), 2))
      out.append((b, max(0.3, cost)))
    }
    return out
  }

  func topFrequencies(_ lex: Lexicon, _ range: Range<Int>, _ n: Int, scanLimit: Int = 4000) -> [(Int, Int)] {
    var best: [(Int, Int)] = []
    for i in range.prefix(scanLimit) {
      let f = lex.frequency(i)
      guard f > 0, best.count < n || f > best[best.count - 1].1 else { continue }
      best.append((i, f))
      best.sort { $0.1 > $1.1 }
      if best.count > n { best.removeLast() }
    }
    return best
  }

  /// "Helo" -> "Hello", "HELO" -> "HELLO"; a proper noun or acronym in the lexicon keeps its own capitals.
  public static func applyCase(of typed: String, to word: String) -> String {
    guard let first = typed.first else { return word }
    if typed.count >= 2, typed == typed.uppercased(), typed != typed.lowercased() { return word.uppercased() }
    if first.isUppercase, let w = word.first { return String(w).uppercased() + word.dropFirst() }
    return word
  }
}
