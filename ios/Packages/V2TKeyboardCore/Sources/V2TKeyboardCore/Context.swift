import Foundation

/// The words before the cursor (before the word being typed or swiped), for the language prior and the
/// next-word statistics.
public struct TypingContext: Sendable, Equatable {
  /// Up to `maxWords` whole words, oldest first, as written.
  public let words: [String]
  /// Nothing but a sentence end (or the start of the field) separates the last word from the cursor.
  public let sentenceStart: Bool
  static let maxWords = 6

  public init(words: [String], sentenceStart: Bool) {
    self.words = words
    self.sentenceStart = sentenceStart
  }

  /// Reads the text before the cursor; a word still being typed must already be cut off.
  public init(before: String) {
    var words: [String] = []
    var current = ""
    var sentenceStart = true  // until a word is seen after the last sentence end
    for ch in before.suffix(160) {
      if ch.isLetter || ((ch == "'" || ch == "’") && !current.isEmpty) {
        current.append(ch == "’" ? "'" : ch)
        continue
      }
      if !current.isEmpty { words.append(current); current = ""; sentenceStart = false }
      if ".!?\n".contains(ch) { sentenceStart = true }
      else if ch.isNumber { sentenceStart = false }
    }
    if !current.isEmpty { words.append(current); sentenceStart = false }
    self.init(words: Array(words.suffix(Self.maxWords)), sentenceStart: sentenceStart)
  }

  public static let empty = TypingContext(words: [], sentenceStart: true)

  /// The word right before the cursor, or nil at the start of a sentence.
  public var previous: String? { sentenceStart ? nil : words.last }

  /// The words that often follow the previous one (or start a sentence) in `lex`, likeliest first. Empty when
  /// the previous word is not in `lex`.
  public func followers(in lex: Lexicon) -> [Lexicon.Follower] {
    guard lex.bigramCount > 0 else { return [] }
    if let p = previous {
      guard let e = lex.entry(of: p) else { return [] }
      return lex.followers(of: e)
    }
    return lex.followers(of: nil)
  }

  /// Nats to add to each entry of `lex` that often follows the previous word: `weight` times its lift.
  public func followerBonus(in lex: Lexicon, weight: Double) -> [Int: Double] {
    var out: [Int: Double] = [:]
    for f in followers(in: lex) where f.lift > 0 { out[f.entry] = weight * f.lift }
    return out
  }
}

/// Which suggestion language the user is writing in, as a log prior per lexicon: 0 for the likeliest,
/// negative for the others. With no words to go on, the language last written in is the likeliest, else the
/// layout's.
public struct LanguagePrior: Sendable {
  /// Prior of a language other than the last one written in (or the layout's), before the context's words
  /// are read, in nats. Tuned on QualityEval: 2 beat 1 on the English rows, and matched it on the Spanish
  /// ones once the last language is remembered.
  public var otherLanguage: Double = 2
  /// The language of the last words written, in this field or an earlier one; nil before any.
  public var recentLanguage: String?
  /// Most a language can lose to the likeliest one, in nats.
  public var cap: Double = 6
  /// Nats between the commonest and the rarest known word, when reading the context.
  static let frequencyScale: Double = 10
  /// What a context word missing from a lexicon costs that language, beyond its rarest word.
  static let unknownWord: Double = 3
  /// The most a context word of `shortWord` letters moves one language against another, in nats. The English
  /// list holds no single letters but "a" and "I", so a "u" or an "o" (Spanish words, and in English a chat
  /// spelling or a slip) counted as an unknown word, 13 nats against English, more than the English words before
  /// it ("Can u" read as Spanish, 3.9 nats ahead; at 1 English leads by 3.6, "Oki u" by 1, where 2 ties).
  /// Infinity weighs them as any word. 0, 1, 2 and infinity move no row of QualityEval, and 0, 1 and infinity
  /// none of LanguageEval.
  public var shortWordCap: Double = 1
  static let shortWord = 1

  public init() {}

  public func priors(_ lexicons: [Lexicon], primary: String?, context: TypingContext) -> [Double] {
    guard lexicons.count > 1 else { return lexicons.map { _ in 0 } }
    let scores = evidence(lexicons, primary: primary, context: context)
    let best = scores.max() ?? 0
    return scores.map { -min(cap, best - $0) }
  }

  /// The language the context's words are likeliest in, or nil when there are none.
  public func likeliest(_ lexicons: [Lexicon], primary: String?, context: TypingContext) -> String? {
    guard !context.words.isEmpty, !lexicons.isEmpty else { return nil }
    let scores = evidence(lexicons, primary: primary, context: context)
    return lexicons[scores.indices.max { scores[$0] < scores[$1] }!].language
  }

  func evidence(_ lexicons: [Lexicon], primary: String?, context: TypingContext) -> [Double] {
    let base = recentLanguage ?? primary
    let baseIndex = lexicons.firstIndex { $0.language == base } ?? 0
    var scores = lexicons.indices.map { $0 == baseIndex ? 0 : -otherLanguage }
    for w in context.words {
      let each = lexicons.map { lex in
        lex.frequency(of: w).map { Self.frequencyScale * (Double($0) / 255 - 1) } ?? -(Self.frequencyScale + Self.unknownWord)
      }
      for (n, e) in capShortWord(w, each).enumerated() { scores[n] += e }
    }
    return scores
  }

  /// A short word's evidence for each language, no language more than `shortWordCap` behind the best.
  func capShortWord(_ word: String, _ evidence: [Double]) -> [Double] {
    guard shortWordCap < .infinity, Lexicon.fold(word).count <= Self.shortWord, let best = evidence.max() else { return evidence }
    return evidence.map { max($0, best - shortWordCap) }
  }
}

/// How a lexicon entry is capitalised, for the penalty a word typed or swiped in lowercase pays for it.
enum EntryCase {
  case lower, name, acronym

  init(_ word: String) {
    guard let first = word.first, first.isUppercase, word != "I", !word.hasPrefix("I'") else { self = .lower; return }
    self = word.count >= 2 && word.allSatisfy { !$0.isLowercase } ? .acronym : .name
  }
}

extension Lexicon {
  /// The entry for `word` written exactly (ignoring case), its commonest spelling: "i" finds "I".
  public func entry(of word: String) -> Int? {
    let lower = word.lowercased()
    var best: Int?
    for i in exactRange(Lexicon.fold(word)) where self.word(i).lowercased() == lower {
      if best == nil || frequency(i) > frequency(best!) { best = i }
    }
    return best
  }

  public func frequency(of word: String) -> Int? { entry(of: word).map(frequency) }
}
