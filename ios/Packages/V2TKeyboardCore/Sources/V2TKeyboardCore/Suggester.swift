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
  /// Letters typed before the commonest longer words are offered as completions.
  public var minCompletionPrefix = 2
  public var beamWidth = 48
  public var maxEdits = 2
  /// A letter typed in place of another that is not next to it on the keyboard: a spelling slip
  /// ("absorbtion", "accomadation") rather than a touch that landed off its key. Infinity turns it off.
  /// Tuned on RealTypoEval's Wikipedia misspellings (RealTypoTuning): off fixed 83.6% of the English ones
  /// and 89.0% of the Spanish; 5 to 8 all fixed 87 to 90% and 91%; 4 and below, or 10, lost the gain.
  public var substitutionPenalty: Double = 7
  /// The same between two vowels, the commonest slip ("seperate", "definate"): 5 beat 7 by 1.5 points on
  /// the English misspellings and matched it on the Spanish.
  public var vowelSubstitutionPenalty: Double = 5
  /// Typed in lowercase, a capitalised entry (a name: "Ford" for "doed") is less likely meant.
  public var properNounPenalty: Double = 2.0
  /// Nats a correction must beat the word as typed by before autocorrect applies it.
  public var autocorrectMargin: Double = 2.0
  /// An all-capitals entry (an acronym) typed in lowercase, on top of `properNounPenalty`.
  public var acronymPenalty: Double = 2
  public var languagePrior = LanguagePrior()
  /// Nats per nat of bigram lift, as MultiSwipeDecoder's.
  public var bigramWeight: Double = 1

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
  /// `context` (the words before this one) sets each language's prior and promotes the words that often
  /// follow the previous one.
  public func suggestions(for typed: [TypedKey], context: TypingContext = .empty, limit: Int = 3) -> [Suggestion] {
    let literal = String(typed.map(\.character))
    let folded = Lexicon.fold(literal)
    guard !folded.isEmpty else { return [] }
    let states = search(typed)
    var scored: [String: Suggestion] = [:]
    let typedLower = literal == literal.lowercased()
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: context)
    let bonuses = bigramWeight > 0 ? lexicons.map { context.followerBonus(in: $0, weight: bigramWeight) } : lexicons.map { _ in [:] }
    func offer(_ word: String, _ kind: Suggestion.Kind, _ raw: Double) {
      var score = raw
      if typedLower {
        switch EntryCase(word) {
        case .lower: break
        case .name: score -= properNounPenalty
        case .acronym: score -= properNounPenalty + acronymPenalty
        }
      }
      let w = Self.applyCase(of: literal, to: word)
      if let old = scored[w.lowercased()], old.score >= score { return }
      scored[w.lowercased()] = Suggestion(word: w, kind: kind, score: score)
    }
    for s in states {
      let lex = lexicons[s.lex]
      let lang = priors[s.lex], bonus = bonuses[s.lex]
      // finished words: keys equal to the prefix
      var i = s.range.lowerBound
      while i < s.range.upperBound, lex.keyLength(i) == s.prefix.count {
        let f = lex.frequency(i)
        if f > 0 || lex.word(i).lowercased() == literal.lowercased() {
          let w = lex.word(i)
          let kind: Suggestion.Kind = w.lowercased() == literal.lowercased() ? .typed : .correction
          offer(w, kind, -s.cost + prior(f) + lang + (bonus[i] ?? 0))
        }
        i += 1
      }
      // completions: the commonest longer words in the range, and the likely next words that complete it
      if s.prefix.count >= minCompletionPrefix || !bonus.isEmpty {
        var seen = Set<Int>()
        let followers = bonus.keys.filter { $0 >= i && $0 < s.range.upperBound }.map { ($0, lex.frequency($0)) }
        let common = s.prefix.count >= minCompletionPrefix ? topFrequencies(lex, i..<s.range.upperBound, 3) : []
        for (j, f) in common + followers where seen.insert(j).inserted {
          let extra = lex.keyLength(j) - s.prefix.count
          offer(lex.word(j), .completion, -s.cost + prior(f) - completionPenalty * Double(extra) - 0.5 + lang + (bonus[j] ?? 0))
        }
      }
    }
    // ties by word: a dictionary's order changes from one launch to the next
    var out = scored.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
    // the literal word keeps a slot even when it is not a word, so it can always be chosen as typed
    if !out.prefix(limit).contains(where: { $0.word.lowercased() == literal.lowercased() }) {
      out.insert(Suggestion(word: literal, kind: .typed, score: -.infinity), at: min(out.count, limit - 1))
    }
    return Array(out.prefix(limit))
  }

  /// The replacement autocorrect should apply when the word is finished, or nil to leave it as typed.
  public func autocorrection(for typed: [TypedKey], learned: Set<String> = [], context: TypingContext = .empty) -> String? {
    let literal = String(typed.map(\.character))
    let lower = literal.lowercased()
    guard Lexicon.fold(literal).count >= 1, !learned.contains(lower) else { return nil }
    // the search sees letters only, so a correction would drop the digits ("hello1" -> "hello")
    guard !literal.contains(where: \.isNumber) else { return nil }
    if lower == "i", lexicons.contains(where: { $0.language == "en" }) { return "I" }
    guard typed.count >= 2 else { return nil }
    // a capitalised word in mid-sentence is likely a name the lists lack ("Figma", "Susan"): left as typed
    // (ios/AUTOCORRECT.md item 8) rather than turned into a word ("Usan") or another name ("Kian" -> "Lian");
    // the bar still offers the corrections ("Londno": London)
    // a real word, as typed, stays, unless it is a rare spelling of a common word with an apostrophe or
    // accent ("cant", "ano") or an i that should be I ("i'm"); a missing accent or apostrophe on a non-word
    // ("cancion", "dont") is corrected below
    if isWord(literal) { return markedVariant(of: literal) }
    // a possessive of a real word ("parents'", "Tom's") keeps its apostrophe
    for suffix in ["'", "'s"] where Self.straightApostrophes(lower).hasSuffix(suffix) {
      if isWord(String(literal.dropLast(suffix.count))) { return nil }
    }
    // look past the bar's three slots: completions may fill them, but only a correction autocorrects
    let all = suggestions(for: typed, context: context, limit: 10)
    guard let best = all.first(where: { $0.kind == .correction }) else { return nil }
    // a capitalised word in mid-sentence is likely a name (ios/AUTOCORRECT.md item 8): it may become a name
    // the lists know ("Britian" -> "Britain") but never a common word ("Figma" -> "Firma", "Susan" -> "Usan").
    // An unknown name can still become a known one ("Kian" -> "Lian"); never correcting names lost 1.9
    // points of RealTypoEval's English fixes for two fewer changed words in 14,000 of correct text.
    if !context.sentenceStart, Self.isTitleCase(literal), !isNameEntry(best.word) { return nil }
    let typedScore = all.first { $0.kind == .typed }?.score ?? -.infinity
    return best.score - typedScore >= autocorrectMargin || typedScore == -.infinity ? best.word : nil
  }

  /// Frequency steps (0-255) a spelling with an apostrophe or accent must beat the word as typed by to replace
  /// it. From the lists: the rare words that should change sit 88 to 154 steps under their marked spelling
  /// (anos/años 88, cant/can't 90, wont/won't 108, whats/what's 154); the common words that must stay sit at
  /// most 52 under (ill/I'll 52, lets/let's 39, id/I'd 37) or above it (were/we're, como/cómo).
  public var markedVariantGap = 80

  /// For a real word typed with plain letters, the much commoner spelling of the same letters with an
  /// apostrophe or accent; for "i'm", "i'll" and the like, the capital I. Nil to leave the word as typed.
  func markedVariant(of literal: String) -> String? {
    let lower = Self.straightApostrophes(literal.lowercased())
    let key = Lexicon.fold(literal)
    if lower.hasPrefix("i'"), literal.first == "i" {
      // the capital only: a curly apostrophe typed stays ("i’m" -> "I’m")
      for lex in lexicons where lex.exactRange(key).contains(where: { lex.word($0).lowercased() == lower && lex.word($0).hasPrefix("I'") }) {
        return "I" + literal.dropFirst()
      }
    }
    guard literal.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }  // marks the user typed stay
    var typed = -1, best: (word: String, frequency: Int)?
    for lex in lexicons {
      for i in lex.exactRange(key) {
        let w = lex.word(i), f = lex.frequency(i)
        if w.lowercased() == lower { typed = max(typed, f); continue }
        guard EntryCase(w) == .lower, !w.allSatisfy(\.isASCII) || w.contains("'") else { continue }
        if best == nil || f > best!.frequency { best = (w, f) }
      }
    }
    guard let b = best, b.frequency - typed >= markedVariantGap else { return nil }
    return Self.applyCase(of: literal, to: b.word)
  }

  /// `word` is in a lexicon as written, ignoring case and which apostrophe was typed ("don’t").
  func isWord(_ word: String) -> Bool {
    let lower = Self.straightApostrophes(word.lowercased())
    let key = Lexicon.fold(word)
    guard !key.isEmpty else { return false }
    return lexicons.contains { lex in lex.exactRange(key).contains { lex.word($0).lowercased() == lower } }
  }

  /// "Figma": a capital first and lowercase after (not "NASA", which typing in capitals produces).
  static func isTitleCase(_ s: String) -> Bool {
    guard let f = s.first, f.isUppercase else { return false }
    return s.dropFirst().contains(where: \.isLowercase)
  }

  /// `word` is a lexicon entry spelled as a name, exactly as written ("London"; not "FIMA" or "Dogma").
  func isNameEntry(_ word: String) -> Bool {
    guard EntryCase(word) == .name else { return false }
    let key = Lexicon.fold(word)
    return lexicons.contains { lex in lex.exactRange(key).contains { lex.word($0) == word } }
  }

  /// The lexicons spell apostrophes straight; the long press types the curly one.
  static func straightApostrophes(_ s: String) -> String { s.replacingOccurrences(of: "’", with: "'") }

  /// The likeliest next words before anything of the next word is typed, best first: the words that most
  /// often follow the previous one (or start a sentence), in the language the context is written in.
  public func predictions(context: TypingContext, limit: Int = 3) -> [Suggestion] {
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: context)
    var best: [String: Suggestion] = [:]
    for (n, lex) in lexicons.enumerated() {
      for f in context.followers(in: lex) {
        let w = lex.word(f.entry), score = f.logProbability + priors[n]
        if let old = best[w.lowercased()], old.score >= score { continue }
        best[w.lowercased()] = Suggestion(word: w, kind: .prediction, score: score)
      }
    }
    return Array(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }.prefix(limit))
  }

  static let vowels: Set<UInt8> = Set("aeiou".utf8)

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
        let kids = lex.children(s.prefix, in: s.range)
        // another letter than the touch's key or its neighbours
        let hitVowel = Self.vowels.contains(h)
        for (x, r) in kids where !options.contains(where: { $0.0 == x }) {
          let cost = hitVowel && Self.vowels.contains(x) ? vowelSubstitutionPenalty : substitutionPenalty
          if cost < .infinity { next.append(State(lex: s.lex, range: r, prefix: s.prefix + [x], cost: s.cost + cost, edits: s.edits + 1)) }
        }
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
          for (x, xr) in kids {
            let p = s.prefix + [x, h]
            let r = lex.prefixRange(p, in: xr)
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
