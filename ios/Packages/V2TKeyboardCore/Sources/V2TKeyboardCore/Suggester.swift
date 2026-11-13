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
  public enum Kind: Sendable { case typed, correction, completion, prediction, emoji }
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
  /// Touch spread in key widths. NoisyTypingEval's real phone taps want it wider: on its test split 0.5 fixed 73.0%
  /// of the mistapped words against 70.9% at 0.42 (72.0% and 71.3% on full-size keyboards), with fewer wrong words.
  /// (Measured before `runnerUpLead`; with it the 0.42 row is 69.4%.)
  /// It stays at 0.42 because the taps at key centres want it narrow: 0.46 already made 31 more English and 23
  /// more Spanish wrong words on RealTypoEval's misspellings, and QualityEval's bar lost words after two and three
  /// letters. The neighbour floor (0 to 1) moved no development row by more than 0.4 points; a cutoff of 2.2 or 2.6
  /// key widths matched 1.8, and 1.4 fixed 2.3 points fewer.
  public var touchStd: Double = 0.42
  /// The least a neighbour of the key hit costs, however close the touch was to it.
  public var neighbourFloor: Double = 0.3
  /// Keys further than this from the touch, in key widths, are not offered for it.
  public var neighbourCutoff: Double = 1.8
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
  /// Skipping a word's first touch ("hvent" read as "vent") or reading it as a letter that is not next to it
  /// ("fnd" as "and"), on top of the usual cost: the first letter is the one a typist most reliably means. 0
  /// treats it as any other touch. On RealTypoEval's misspellings, with the three weights below, 2 fixed 13 more
  /// English and 3 more Spanish ones than 0 and made 14 and 13 fewer wrong words; 3 did no better.
  public var firstTouchPenalty: Double = 2
  /// A last letter left off ("som" for "some", "agre" for "agree") as a correction autocorrect may apply, at this
  /// cost (half for a doubled letter, as inside a word). Infinity leaves such words to the bar's completions.
  /// At 5, `editPenalty`'s value, RealTypoEval fixed 35 more English and 51 more Spanish misspellings than
  /// without it and made 20 and 18 fewer wrong words; 4 and 7 did no better.
  public var lastLetterPenalty: Double = 5
  /// The lowest score a correction of something that is not a word may have and still be applied: below it the
  /// letters stay as typed rather than become an unlikely word. -infinity applies the best correction whatever
  /// it scores. On RealTypoEval -18 left 12 English and 43 Spanish misspellings unfixed that -infinity fixed, and
  /// kept 44 and 97 from becoming a wrong word; -16 gave up 28 and 127 fixes for 62 and 194, -20 only 4 and 6
  /// for 31 and 59.
  public var correctionFloor: Double = -18
  /// Nats by which a commoner word that goes on past the letters typed ("th": the, this) must beat the best
  /// correction ("to") for the letters to count as a word not yet finished: autocorrect then leaves them, and the
  /// bar keeps its completions. Infinity never leaves a correction for a completion. At 1, with the three weights
  /// above, RealTypoEval fixed 89.5% of the English misspellings and 90.9% of the Spanish (89.6% and 91.1% before
  /// any of them) and made a wrong word of 6.2% and 6.7% (8.9% and 8.2%); 0 gave up another point of fixes, and
  /// from 2 up QualityEval's bar lost the meant word after two letters.
  public var completionLead: Double = 1
  /// The nats the best correction must beat the next different word by; closer than that and the letters stay
  /// as typed, since either word may be the one meant ("ica" in a typing log became "ova", 0.1 ahead of "ice",
  /// where "I can" was meant). 0 turns the rule off. On RealTypoEval each step gives up about one fix for one
  /// wrong word avoided: 0.25 lost 33 English and 116 Spanish fixes and avoided 40 and 172 wrong words, 0.5
  /// lost 72 and 224 for 72 and 328, 0.75 lost 115 and 348 for 95 and 428, 1 lost 157 and 487 for 121 and 534.
  /// At 0.5 the two typing logs keep every correction that was right ("fnd" -> "find", "som" -> "some");
  /// 0.75 leaves those two as typed.
  public var runnerUpLead: Double = 0.5
  /// How many times in a row a letter is typed before it counts as stretched on purpose ("saaame", "nooo",
  /// "yesss"). Letters with such a run stay as typed, except one tap too many on a double letter ("boook" ->
  /// "book", "cannnot" -> "cannot"), and a run one longer is never corrected. `Int.max` turns the rule off.
  /// RealTypoEval has 15 English and 4 Spanish misspellings with a run of three, none longer; all but two
  /// ("asssassans", "resssurecting") are the extra tap. Without the rule "saaame" became "salaam", "soooo"
  /// "soon" and "yessss" "yeasts".
  public var stretchedRun = 3
  /// A space left out between two words ("needsme", "Weneed"): letters that are two words of one list, the
  /// second among the words that most often follow the first (the next-word statistics), become the two words
  /// when they score above the best correction. The pair scores as the first word would as a correction typed
  /// exactly, plus ln P(second | first), less this many nats. Infinity turns the rule off. With one space taken
  /// out of NoisyTypingEval's Enron sentences (MissingSpaceEval), 3 puts back 41.9% of the pairs and makes a
  /// wrong word of 19.2% (none and 41.0% without the rule); 5 and 7 put back 37.5% and 28.7%. On RealTypoEval 3
  /// costs 1 Spanish fix for 1 more wrong word, 0 cost 1 English and 4 Spanish fixes for 1 and 5.
  public var missingSpacePenalty: Double = 3
  /// Letters that are two words of one list, each three letters or more, that `missingSpacePenalty` does not
  /// take as a pair and whose best correction scores under this, are a compound the list lacks rather than a
  /// slip ("changelog": change, log; its correction "changeling" scored -15.0): autocorrect leaves them as typed
  /// instead of making a third word of them. -infinity turns the rule off. Of the 36,703 words of Webster's
  /// Second the English list lacks that are two English words (MissingSpaceEval), -14 makes another word of
  /// 10.4% (25.3% without the rule). On RealTypoEval -14 gave up 9 English and 15 Spanish fixes for 2 and 12
  /// fewer wrong words, -12 gave up 19 and 45 for 5 and 22, and -16 0 and 4 for 2 and 4 but leaves "changelog"
  /// (-15.0) to become "changeling". Leaving every such word as typed, whatever its correction scored, lost 10
  /// points of English fixes.
  public var compoundFloor: Double = -14
  /// When the language being written knows no words that follow the previous one, another language's do not
  /// count either (in the bar's next words, or as a bonus to its completions) unless that language is within this
  /// many nats of it (`followerLanguages`): after "Can u" the words that follow Spanish "u" (otros, otra) are
  /// not offered in an English sentence. Infinity lets every language's count as before. 0, 1 and infinity
  /// move no row of QualityEval or LanguageEval (RealTypoEval's Tatoeba sentences and the Enron ones, 34,000 next
  /// words and first letters); 0 keeps the bar English after "I'd le", where Spanish is 0.47 behind.
  public var followerLanguageGap: Double = 0
  /// A real word typed with one touch near the edge of its key ("Gappy" with the G touched by the H): the word
  /// the neighbouring key makes replaces it when that neighbour cost no more than `ambiguousTapCost` nats and the
  /// word, with the words before it, scores `ambiguousTapGap` nats above the one typed. A cost of -infinity turns
  /// the rule off. On NoisyTypingEval's development split 1 and 2 fix 172 more mistapped words (74.2% to 77.1%)
  /// for 14 more wrong words and 1 more word tapped right changed; on the test split 478 more (69.3% to 71.7%)
  /// for 36 (7.6% to 7.8%). A cost of 0.5 with a gap of 4 fixed 48 more for 6; 2 and 2, 208 for 17; a gap of 0
  /// changed 31 words tapped right. RealTypoEval does not move: at a key's centre no neighbour costs under 3
  /// nats.
  public var ambiguousTapCost: Double = 1
  public var ambiguousTapGap: Double = 2

  private let centers: [CGPoint?]
  private let memoLock = NSLock()
  /// The beams of the last word searched, `beams[n]` before its nth letter: the next key carries the search on
  /// from where the last one stopped, and a delete steps back, rather than each key searching the word from
  /// its first letter (the bar took 17 to 23 ms a key ten letters into a word on an iPhone 17 Pro).
  private var searchMemo: (keys: [TypedKey], beams: [[State]], tuning: [Double], lexicons: [ObjectIdentifier])?
  /// The last word ranked: the bar, the bold slot and the emoji lookup all ask about the same letters after a key.
  private var rankMemo: (keys: [TypedKey], context: TypingContext, tuning: [Double], lexicons: [ObjectIdentifier], ranking: Ranking)?

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
    guard !Lexicon.fold(literal).isEmpty else { return [] }
    var out = ranking(for: typed, context: context).bar
    // the literal word keeps a slot even when it is not a word, so it can always be chosen as typed
    if !out.prefix(limit).contains(where: { $0.word == literal }) {
      out.insert(Suggestion(word: literal, kind: .typed, score: -.infinity), at: min(out.count, limit - 1))
    }
    return Array(out.prefix(limit))
  }

  /// Every word the letters typed could be, best first.
  struct Ranking {
    /// Finished words and completions, as the bar ranks them.
    var bar: [Suggestion]
    /// Words one letter longer than what was typed, scored as corrections (a last letter left off).
    var lastLetter: [Suggestion]
    /// The finished words that are not the letters as typed, at their score as a correction. The bar holds each
    /// word once, at its best score, which for some is as a completion of fewer letters ("belive": believe).
    var corrections: [Suggestion]
  }

  /// What `search` depends on besides the keys.
  private var searchTuning: [Double] {
    [touchStd, neighbourFloor, neighbourCutoff, editPenalty, substitutionPenalty, vowelSubstitutionPenalty, firstTouchPenalty, Double(beamWidth), Double(maxEdits)]
  }

  /// What a ranking depends on besides the keys, the words before them and the search.
  private var rankTuning: [Double] {
    searchTuning + [frequencyWeight, completionPenalty, Double(minCompletionPrefix), properNounPenalty, acronymPenalty, bigramWeight,
                    lastLetterPenalty, languagePrior.otherLanguage, languagePrior.cap, languagePrior.shortWordCap, followerLanguageGap]
      + (languagePrior.recentLanguage.map { $0.unicodeScalars.map { Double($0.value) } } ?? [])
  }

  func ranking(for typed: [TypedKey], context: TypingContext) -> Ranking {
    let tuning = rankTuning, ids = lexicons.map { ObjectIdentifier($0) }
    memoLock.lock()
    let memo = rankMemo
    memoLock.unlock()
    if let m = memo, m.keys == typed, m.context == context, m.tuning == tuning, m.lexicons == ids { return m.ranking }
    let r = rank(typed, context: context)
    memoLock.lock()
    rankMemo = (typed, context, tuning, ids, r)
    memoLock.unlock()
    return r
  }

  private func rank(_ typed: [TypedKey], context: TypingContext) -> Ranking {
    let literal = String(typed.map(\.character))
    let states = search(typed)
    var scored: [String: Suggestion] = [:], lastLetter: [String: Suggestion] = [:], corrections: [String: Suggestion] = [:]
    let typedLower = literal == literal.lowercased()
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: context)
    let followed = followerLanguages(context)
    let bonuses = lexicons.indices.map { bigramWeight > 0 && followed[$0] ? context.followerBonus(in: lexicons[$0], weight: bigramWeight) : [:] }
    func offer(_ word: String, _ kind: Suggestion.Kind, _ raw: Double, lastLetter missed: Bool = false) {
      var score = raw
      if typedLower {
        switch EntryCase(word) {
        case .lower: break
        case .name: score -= properNounPenalty
        case .acronym: score -= properNounPenalty + acronymPenalty
        }
      }
      let w = Self.applyCase(of: literal, to: word)
      if missed {
        if let old = lastLetter[w.lowercased()], old.score >= score { return }
        lastLetter[w.lowercased()] = Suggestion(word: w, kind: kind, score: score)
        return
      }
      if kind == .correction, (corrections[w.lowercased()]?.score ?? -.infinity) < score {
        corrections[w.lowercased()] = Suggestion(word: w, kind: kind, score: score)
      }
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
          // the word as typed only when the bar would write it exactly so ("i'm" is not "I'm")
          let kind: Suggestion.Kind = Self.applyCase(of: literal, to: w) == literal ? .typed : .correction
          offer(w, kind, -s.cost + prior(f) + lang + (bonus[i] ?? 0))
        }
        i += 1
      }
      // completions: the commonest longer words in the range, and the likely next words that complete it
      if s.prefix.count >= minCompletionPrefix || !bonus.isEmpty {
        var seen = Set<Int>()
        let followers = bonus.keys.filter { $0 >= i && $0 < s.range.upperBound }.map { ($0, lex.frequency($0)) }
        let common = s.prefix.count >= minCompletionPrefix ? commonest(lex, s.prefix, i..<s.range.upperBound) : []
        for (j, f) in common + followers where seen.insert(j).inserted {
          let extra = lex.keyLength(j) - s.prefix.count
          offer(lex.word(j), .completion, -s.cost + prior(f) - completionPenalty * Double(extra) - 0.5 + lang + (bonus[j] ?? 0))
        }
      }
      // a last letter left off: the words one letter longer, at the cost of a letter missed inside a word
      if lastLetterPenalty < .infinity, s.edits < maxEdits, !s.prefix.isEmpty {
        for (x, r) in lex.children(s.prefix, in: i..<s.range.upperBound) {
          let cost = x == s.prefix.last ? lastLetterPenalty * 0.5 : lastLetterPenalty
          var j = r.lowerBound
          while j < r.upperBound, lex.keyLength(j) == s.prefix.count + 1 {
            let f = lex.frequency(j)
            if f > 0 { offer(lex.word(j), .correction, -s.cost - cost + prior(f) + lang + (bonus[j] ?? 0), lastLetter: true) }
            j += 1
          }
        }
      }
    }
    // ties by word: a dictionary's order changes from one launch to the next
    func sorted(_ d: [String: Suggestion]) -> [Suggestion] { d.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word } }
    return Ranking(bar: sorted(scored), lastLetter: sorted(lastLetter), corrections: sorted(corrections))
  }

  /// The three commonest words that start with `prefix` and go on, within `range` (the prefix's own entries).
  /// One and two letters are read from the lexicon's table: their ranges run to thousands of words, more than a
  /// scan per key can read, and the scan's cut-off dropped the common words late in the alphabet ("could" from "co").
  func commonest(_ lex: Lexicon, _ prefix: [UInt8], _ range: Range<Int>) -> [(Int, Int)] {
    prefix.count <= 2 ? lex.commonest(after: prefix) : topFrequencies(lex, range, 3)
  }

  /// The replacement autocorrect should apply when the word is finished, or nil to leave it as typed.
  public func autocorrection(for typed: [TypedKey], learned: Set<String> = [], context: TypingContext = .empty) -> String? {
    let literal = String(typed.map(\.character))
    let lower = literal.lowercased()
    guard Lexicon.fold(literal).count >= 1, !learned.contains(lower), !learned.contains(Self.straightApostrophes(lower)) else { return nil }
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
    if isWord(literal) {
      return !context.sentenceStart && Self.isTitleCase(literal) ? nil : markedVariant(of: literal) ?? ambiguousTap(typed, context: context)
    }
    // a possessive of a real word ("parents'", "Tom's") keeps its apostrophe
    for suffix in ["'", "'s"] where Self.straightApostrophes(lower).hasSuffix(suffix) {
      if isWord(String(literal.dropLast(suffix.count))) { return nil }
    }
    // a stretched word is left as typed; with a run of exactly `stretchedRun` the only correction is the same
    // letters with that run one shorter
    let runs = Self.letterRuns(lower)
    let longest = runs.map(\.count).max() ?? 0
    // four or more in a row, or nothing but the one letter ("Mmm", "ooo"), is never a slip on a double letter
    if longest > stretchedRun || (longest == stretchedRun && runs.count == 1) { return nil }
    // compared by letters alone, as the lists spell the word with a straight apostrophe or an accent the
    // typist left to autocorrect ("i’lll": I'll)
    let oneTapFewer: Set<[UInt8]>? = longest == stretchedRun
      ? Set(runs.filter { $0.count == stretchedRun }.map { run in Lexicon.fold(String(lower[..<run.startIndex] + lower[lower.index(after: run.startIndex)...])) })
      : nil
    // two words with the space between them left out ("needsme"); a capitalised word in mid-sentence is a name
    let pair = context.sentenceStart || !Self.isTitleCase(literal) ? missingSpace(in: literal, context: context) : nil
    // look past the bar's three slots: completions may fill them, but only a correction autocorrects
    let all = suggestions(for: typed, context: context, limit: 10)
    // a last letter left off competes with the corrections of the same length ("som": some against son)
    let rank = ranking(for: typed, context: context)
    let candidates = [rank.corrections.first, rank.lastLetter.first].compactMap { $0 }
    guard let best = candidates.max(by: { $0.score < $1.score }) else { return pair?.words }
    if let pair, pair.score >= best.score { return pair.words }
    // two words run together whose pair, if any, lost, and whose best correction is unlikely: a compound the lists
    // lack, left as typed
    if best.score < compoundFloor, isCompound(literal) { return nil }
    if let oneTapFewer, !oneTapFewer.contains(Lexicon.fold(best.word)) { return nil }
    // two different words about as likely as each other ("ica": ova against ice): the letters stay
    let others = (rank.corrections + rank.lastLetter).filter { $0.word.lowercased() != best.word.lowercased() }
    if let second = others.map(\.score).max(), best.score - second < runnerUpLead { return nil }
    // a word one letter longer is in the bar as a completion too, at its score there ("agre": agree beside agreed)
    let shown = all.first { $0.word.lowercased() == best.word.lowercased() }?.score ?? best.score
    if let longer = all.first(where: { $0.kind == .completion }), longer.word.lowercased() != best.word.lowercased(),
       longer.score - max(best.score, shown) >= completionLead { return nil }
    // a capitalised word in mid-sentence is likely a name (ios/AUTOCORRECT.md item 8): it may become a name
    // the lists know ("Britian" -> "Britain") but never a common word ("Figma" -> "Firma", "Susan" -> "Usan").
    // An unknown name can still become a known one ("Kian" -> "Lian"); never correcting names lost 1.9
    // points of RealTypoEval's English fixes for two fewer changed words in 14,000 of correct text.
    if !context.sentenceStart, Self.isTitleCase(literal), !isNameEntry(best.word) { return nil }
    let typedScore = all.first { $0.kind == .typed }?.score ?? -.infinity
    if typedScore == -.infinity { return best.score >= correctionFloor ? best.word : nil }
    return best.score - typedScore >= autocorrectMargin ? best.word : nil
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

  /// The ways `literal` cuts into two words of one lexicon, each a lowercase word the bar may suggest (frequency
  /// above 0; not a name or an acronym: "saaame" is not "SAA" and "Ame"): (lexicon, first entry, second entry).
  func twoWords(_ literal: String, minPart: Int = 1) -> [(lex: Int, first: Int, second: Int)] {
    let letters = Array(literal)
    guard minPart < letters.count, letters.count >= 2 * max(1, minPart), letters.allSatisfy(\.isLetter) else { return [] }
    var out: [(lex: Int, first: Int, second: Int)] = []
    for cut in max(1, minPart)..<letters.count where letters.count - cut >= minPart {
      let a = String(letters[..<cut]), b = String(letters[cut...])
      for (n, lex) in lexicons.enumerated() {
        guard let ea = lex.entry(of: a), lex.frequency(ea) > 0, EntryCase(lex.word(ea)) == .lower,
              let eb = lex.entry(of: b), lex.frequency(eb) > 0, EntryCase(lex.word(eb)) == .lower else { continue }
        out.append((n, ea, eb))
      }
    }
    return out
  }

  /// "needsme" -> "needs me": the likeliest pair of words `literal` is with a space left out, the second (two
  /// letters or more: "Mary" is not "Mar y") among the words that most often follow the first, scored as
  /// `missingSpacePenalty` says; nil when there is none.
  func missingSpace(in literal: String, context: TypingContext) -> (words: String, score: Double)? {
    guard missingSpacePenalty < .infinity else { return nil }
    let cuts = twoWords(literal).filter { lexicons[$0.lex].keyLength($0.second) >= 2 }
    guard !cuts.isEmpty else { return nil }
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: context)
    let followed = followerLanguages(context)
    var best: (words: String, score: Double)?
    for (n, a, b) in cuts {
      let lex = lexicons[n]
      guard let f = lex.followers(of: a).first(where: { $0.entry == b }) else { continue }
      let bonus = bigramWeight > 0 && followed[n] ? context.followerBonus(in: lex, weight: bigramWeight)[a] ?? 0 : 0
      let score = prior(lex.frequency(a)) + priors[n] + bonus + f.logProbability - missingSpacePenalty
      if best == nil || score > best!.score { best = (lex.word(a) + " " + lex.word(b), score) }
    }
    return best.map { (Self.applyCase(of: literal, to: $0.words), $0.score) }
  }

  /// For a real word as typed, the word one touch near the edge of its key makes with the neighbouring key, when
  /// that word is far likelier here (`ambiguousTapCost`, `ambiguousTapGap`); nil to leave the word.
  func ambiguousTap(_ typed: [TypedKey], context: TypingContext) -> String? {
    guard ambiguousTapCost > -.infinity else { return nil }
    let literal = String(typed.map(\.character)), lower = literal.lowercased()
    let keys = typed.map { Lexicon.fold(String($0.character)) }
    guard keys.allSatisfy({ $0.count == 1 }) else { return nil }
    let letters = keys.map { $0[0] }
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: context)
    let followed = followerLanguages(context)
    let bonuses = lexicons.indices.map { bigramWeight > 0 && followed[$0] ? context.followerBonus(in: lexicons[$0], weight: bigramWeight) : [:] }
    let typedLower = literal == lower
    /// The best entry spelled by `key` (only `exactly` when given), scored as the bar scores a finished word.
    func best(_ key: [UInt8], exactly: String? = nil) -> (word: String, score: Double)? {
      var out: (word: String, score: Double)?
      for (n, lex) in lexicons.enumerated() {
        for i in lex.exactRange(key) where lex.frequency(i) > 0 {
          let w = lex.word(i)
          if let e = exactly, w.lowercased() != e { continue }
          var s = prior(lex.frequency(i)) + priors[n] + (bonuses[n][i] ?? 0)
          if typedLower, EntryCase(w) != .lower { s -= properNounPenalty + (EntryCase(w) == .acronym ? acronymPenalty : 0) }
          if out == nil || s > out!.score { out = (w, s) }
        }
      }
      return out
    }
    guard let base = best(letters, exactly: lower) else { return nil }
    let unit = Double(layout.unitWidth)
    var found: (word: String, score: Double)?
    for (i, t) in typed.enumerated() {
      guard let p = t.point else { continue }
      for (c, cost) in letterOptions(letters[i], p, unit: unit) where c != letters[i] && cost <= ambiguousTapCost {
        var k = letters
        k[i] = c
        guard let w = best(k), w.score - cost - base.score >= ambiguousTapGap else { continue }
        if found == nil || w.score - cost > found!.score { found = (w.word, w.score - cost) }
      }
    }
    return found.map { Self.applyCase(of: literal, to: $0.word) }
  }

  /// `literal` is two words of one lexicon, each three letters or more ("changelog": change, log).
  func isCompound(_ literal: String) -> Bool {
    !twoWords(literal, minPart: 3).isEmpty
  }

  /// The lexicons spell apostrophes straight; the long press types the curly one.
  /// The stretches of one letter repeated, each as a slice of `s` ("boook": b, ooo, k).
  static func letterRuns(_ s: String) -> [Substring] {
    var runs: [Substring] = [], start = s.startIndex
    for i in s.indices.dropFirst() where s[i] != s[start] {
      runs.append(s[start..<i])
      start = i
    }
    if start < s.endIndex { runs.append(s[start...]) }
    return runs
  }

  static func straightApostrophes(_ s: String) -> String { s.replacingOccurrences(of: "’", with: "'") }

  /// The likeliest next words before anything of the next word is typed, best first: the words that most
  /// often follow the previous one (or start a sentence), in the language the context is written in.
  public func predictions(context: TypingContext, limit: Int = 3) -> [Suggestion] {
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: context)
    let followed = followerLanguages(context)
    var best: [String: Suggestion] = [:]
    for (n, lex) in lexicons.enumerated() where followed[n] {
      for f in context.followers(in: lex) {
        let w = lex.word(f.entry), score = f.logProbability + priors[n]
        if let old = best[w.lowercased()], old.score >= score { continue }
        best[w.lowercased()] = Suggestion(word: w, kind: .prediction, score: score)
      }
    }
    // no word is known to follow the last one ("benchmark", a name): the commonest words of the language being
    // written, rather than an empty bar
    if best.isEmpty {
      for (n, lex) in lexicons.enumerated() {
        for (i, f) in lex.commonestWords() {
          let w = lex.word(i), score = prior(f) + priors[n]
          if let old = best[w.lowercased()], old.score >= score { continue }
          best[w.lowercased()] = Suggestion(word: w, kind: .prediction, score: score)
        }
      }
    }
    return Array(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }.prefix(limit))
  }

  /// Which lexicons' next-word statistics count after `context`. All of them while the language the last
  /// `followerWindow` words are likeliest in has the previous word as a word ("me", "buenos": English knows
  /// both), and otherwise only the languages within `followerLanguageGap` of that one by those words: a word the
  /// language being written lacks is a slip or a chat spelling there ("te" for "the", "u"), and what follows it
  /// in another language describes a sentence nobody is writing. The last words, not the whole context, so that
  /// two words in another language ("I told her que te") switch.
  func followerLanguages(_ context: TypingContext) -> [Bool] {
    let all = lexicons.map { _ in true }
    guard followerLanguageGap < .infinity, lexicons.count > 1, let previous = context.previous,
          Lexicon.fold(previous).count <= Self.followerShortWord else { return all }
    let recent = TypingContext(words: Array(context.words.suffix(Self.followerWindow)), sentenceStart: context.sentenceStart)
    let priors = languagePrior.priors(lexicons, primary: layout.language.rawValue, context: recent)
    guard let best = priors.indices.max(by: { priors[$0] < priors[$1] }), lexicons[best].entry(of: previous) == nil else { return all }
    return priors.map { $0 >= -followerLanguageGap }
  }

  /// The words before the cursor `followerLanguages` reads: two words of another language in a row switch, and
  /// the previous word and the one before it tell an English "for te" from a Spanish "que te".
  static let followerWindow = 2
  /// The longest previous word `followerLanguages` holds to the language being written: the log's words were
  /// one and two letters (u, o, e, te, le). Any length lost 26 Spanish next words on RealTypoEval's Tatoeba
  /// sentences for 3 gained ("tom tiene": English knows Tom, not tiene).
  static let followerShortWord = 2

  static let vowels: Set<UInt8> = Set("aeiou".utf8)

  func prior(_ f: Int) -> Double { frequencyWeight * (Double(f) / 255 - 1) }

  func search(_ typed: [TypedKey]) -> [State] {
    let u = Double(layout.unitWidth)
    let letters = typed.compactMap { t in Lexicon.fold(String(t.character)).first.map { (t, $0) } }  // apostrophes and hyphens are not in the keys
    let keys = letters.map(\.0), tuning = searchTuning, ids = lexicons.map { ObjectIdentifier($0) }
    memoLock.lock()
    let memo = searchMemo
    memoLock.unlock()
    // beams[n]: the beam before letter n. Carried on from the last search as far as the keys are the same
    var beams: [[State]] = [lexicons.indices.map { State(lex: $0, range: 0..<lexicons[$0].count, prefix: [], cost: 0, edits: 0) }]
    if let m = memo, m.tuning == tuning, m.lexicons == ids {
      var same = 0
      while same < min(m.keys.count, keys.count), m.keys[same] == keys[same] { same += 1 }
      beams = Array(m.beams.prefix(same + 1))
    }
    for n in (beams.count - 1)..<letters.count {
      let (t, h) = letters[n], beam = beams[n]
      guard !beam.isEmpty else { beams.append([]); continue }
      let options = letterOptions(h, t.point, unit: u)
      // two letters swapped ("becuase"): the states before the last letter that took this one first, then it
      var next: [State] = []
      if n >= 1 {
        let h1 = letters[n - 1].1
        for s in beams[n - 1] where s.edits < maxEdits && h != h1 {
          let p = s.prefix + [h, h1]
          let r = lexicons[s.lex].prefixRange(p, in: s.range)
          if !r.isEmpty { next.append(State(lex: s.lex, range: r, prefix: p, cost: s.cost + editPenalty * 0.8, edits: s.edits + 1)) }
        }
      }
      next.reserveCapacity(next.count + beam.count * (options.count + 2))
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
          let cost = (hitVowel && Self.vowels.contains(x) ? vowelSubstitutionPenalty : substitutionPenalty) + (n == 0 ? firstTouchPenalty : 0)
          if cost < .infinity { next.append(State(lex: s.lex, range: r, prefix: s.prefix + [x], cost: s.cost + cost, edits: s.edits + 1)) }
        }
        // this touch was a mistake: skip it
        next.append(State(lex: s.lex, range: s.range, prefix: s.prefix, cost: s.cost + editPenalty + (n == 0 ? firstTouchPenalty : 0), edits: s.edits + 1))
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
      // one state per (lexicon, prefix), the cheapest, and `beamWidth` of them per lexicon: one beam for all
      // halved each language's share with a second one on (RealTypoEval's English misspellings typed with
      // Spanish on: 88.5% fixed at 24 a lexicon, 89.3% at 48)
      var seen = Set<[UInt8]>(), kept: [State] = [], perLexicon = [Int](repeating: 0, count: lexicons.count)
      for s in next where perLexicon[s.lex] < beamWidth {
        if seen.insert([UInt8(s.lex)] + s.prefix).inserted { kept.append(s); perLexicon[s.lex] += 1 }
      }
      beams.append(kept)
    }
    memoLock.lock()
    searchMemo = (keys, beams, tuning, ids)
    memoLock.unlock()
    return beams[letters.count]
  }

  /// The letters a touch may have meant with their spatial costs: the hit key free, neighbours by distance.
  func letterOptions(_ hit: UInt8, _ point: CGPoint?, unit: Double) -> [(UInt8, Double)] {
    guard let p = point else { return [(hit, 0)] }
    var out: [(UInt8, Double)] = [(hit, 0)]
    let hd = centers[Int(hit)].map { Double(hypot($0.x - p.x, $0.y - p.y)) } ?? 0
    for b in UInt8(97)...UInt8(122) where b != hit {
      guard let c = centers[Int(b)] else { continue }
      let d = Double(hypot(c.x - p.x, c.y - p.y))
      guard d < neighbourCutoff * unit else { continue }
      // relative to the hit key, so a touch on a key's edge makes its neighbour nearly as likely
      let cost = 0.5 * (pow(d / (touchStd * unit), 2) - pow(hd / (touchStd * unit), 2))
      out.append((b, max(neighbourFloor, cost)))
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
