import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Autocorrect's rules for letters that are not a word, each on a word with the touches a real typing log
/// recorded (iPhone 17 Pro, 402 pt wide, English and Spanish on; ios/README.md, "Keyboard debug log") or on a
/// misspelling from RealTypoEval's lists typed at the key centres. Each rule's weight has a control: with the
/// rule off, the old answer comes back.
struct AutocorrectRulesTests {
  static let layout = KeyboardLayout(width: 402, language: .english)

  static func keys(_ touches: [(Character, Double, Double)]) -> [TypedKey] { touches.map { TypedKey($0.0, at: CGPoint(x: $0.1, y: $0.2)) } }
  // "but he hvent", "I also got som", "by my lov", "we wanre", as the fingers landed
  static let hvent = keys([("h", 230.7, 73), ("v", 196.3, 129.3), ("e", 91.3, 34), ("n", 291, 127), ("t", 169, 33.7)])
  static let som = keys([("s", 73.7, 97.3), ("o", 348.7, 28.3), ("m", 318.3, 135.7)])
  static let lov = keys([("l", 360, 88.7), ("o", 338.7, 39.7), ("v", 190.3, 140.7)])
  // "actually ica" (I can), from a second log of the same phone on build 124
  static let ica = keys([("i", 314, 26), ("c", 173.7, 120.7), ("a", 40.3, 79.3)])
  static let wanre = keys([("w", 47.3, 38.3), ("a", 26, 86), ("n", 281.3, 153.3), ("r", 149.7, 42), ("e", 86, 45)])

  func suggester(_ change: (Suggester) -> Void = { _ in }) throws -> Suggester {
    let s = Suggester(lexicons: [try Fixtures.english.get(), try Fixtures.spanish.get()], layout: Self.layout)
    change(s)
    return s
  }

  @Test func aFirstLetterIsKeptRatherThanDropped() throws {
    let context = TypingContext(before: "model but ")
    #expect(try suggester().autocorrection(for: Self.hvent, context: context) == "haven't")
    #expect(try suggester { $0.firstTouchPenalty = 0; $0.runnerUpLead = 0 }.autocorrection(for: Self.hvent, context: context) == "vent")
  }

  @Test(arguments: [(som, "I also got ", "some"), (lov, "by my ", "love"), (taps("agre", layout), "I think the ", "agree")])
  func aLastLetterLeftOffIsPutBack(typed: [TypedKey], before: String, expected: String) throws {
    let context = TypingContext(before: before)
    #expect(try suggester().autocorrection(for: typed, context: context) == expected)
    #expect(try suggester { $0.lastLetterPenalty = .infinity }.autocorrection(for: typed, context: context) == nil)
  }

  @Test func lettersThatACommonerLongerWordStartsWithAreLeftAsTyped() throws {
    let context = TypingContext(before: "sizes we ")
    #expect(try suggester().autocorrection(for: Self.wanre, context: context) == nil)  // "wanted" is in the bar
    #expect(try suggester { $0.completionLead = .infinity }.autocorrection(for: Self.wanre, context: context) == "wants")
  }

  @Test func aCorrectionTooUnlikelyIsNotApplied() throws {
    let typed = taps("catapiller", Self.layout), context = TypingContext(before: "I think the ")
    #expect(try suggester().autocorrection(for: typed, context: context) == nil)
    #expect(try suggester { $0.correctionFloor = -.infinity }.autocorrection(for: typed, context: context) == "catapult")
  }

  /// A letter typed three or more times in a row is stretched on purpose; the second word is the answer
  /// without the rule.
  @Test(arguments: [("saaame", "salaam"), ("soooo", "soon"), ("nooo", "noon"), ("yessss", "yeasts"), ("hmmm", "hamm")])
  func aStretchedWordIsLeftAsTyped(word: String, before: String) throws {
    let typed = taps(word, Self.layout), context = TypingContext(before: "I think the ")
    #expect(try suggester().autocorrection(for: typed, context: context) == nil)
    #expect(try suggester { $0.stretchedRun = .max; $0.runnerUpLead = 0 }.autocorrection(for: typed, context: context) == before)
  }

  @Test(arguments: [("boook", "book"), ("cannnot", "cannot"), ("agreeement", "agreement"), ("caballlo", "caballo")])
  func oneTapTooManyOnADoubleLetterIsCorrected(word: String, expected: String) throws {
    #expect(try suggester().autocorrection(for: taps(word, Self.layout), context: TypingContext(before: "I think the ")) == expected)
  }

  /// The lists spell the word with a straight apostrophe; the typist's may be curly.
  @Test(arguments: ["you'lll", "you’lll"])
  func oneTapTooManyIsCorrectedAcrossAnApostrophe(word: String) throws {
    let typed = taps(word, Self.layout), context = TypingContext(before: "I think ")
    #expect(try suggester().autocorrection(for: typed, context: context).map(Suggester.straightApostrophes) == "you'll")
  }

  @Test func aRunOneLongerThanADoubleLetterSlipIsNeverCorrected() throws {
    let typed = taps("booook", Self.layout), context = TypingContext(before: "I think the ")
    #expect(try suggester().autocorrection(for: typed, context: context) == nil)
    #expect(try suggester { $0.stretchedRun = .max }.autocorrection(for: typed, context: context) == "book")
  }

  /// "Mmm" in a typing log was about to become "Mm": one tap fewer, but the whole word is the stretch.
  @Test func aWordThatIsOnlyOneLetterStretchedIsLeftAsTyped() throws {
    let typed = taps("mmm", Self.layout), context = TypingContext(before: "I think ")
    #expect(try suggester().autocorrection(for: typed, context: context) == nil)
    #expect(try suggester { $0.stretchedRun = .max; $0.runnerUpLead = 0 }.autocorrection(for: typed, context: context) != nil)
  }

  @Test func letterRunsSplitAWordWhereTheLetterChanges() {
    #expect(Suggester.letterRuns("boook").map(String.init) == ["b", "ooo", "k"])
    #expect(Suggester.letterRuns("aab").map(String.init) == ["aa", "b"])
    #expect(Suggester.letterRuns("").isEmpty)
  }

  /// "ova" led "ice" by 0.1: with two words that close, neither is put in.
  @Test func lettersWithTwoCorrectionsAboutAsLikelyAreLeftAsTyped() throws {
    let context = TypingContext(before: "smooth actually ")
    #expect(try suggester().autocorrection(for: Self.ica, context: context) == nil)
    #expect(try suggester { $0.runnerUpLead = 0 }.autocorrection(for: Self.ica, context: context) == "ova")
  }

  /// The bar holds "believe" as a completion of fewer letters, which outranks it as a correction of all six.
  @Test func aWordTheBarRanksAsACompletionIsStillACorrection() throws {
    let typed = taps("belive", Self.layout), context = TypingContext(before: "I think the ")
    #expect(try suggester().autocorrection(for: typed, context: context) == "believe")
  }

  func engine(_ before: String, _ change: (Suggester) -> Void = { _ in }) throws -> TypingEngine {
    let p = FakeProxy()
    p.text = before
    let e = TypingEngine(proxy: p, suggester: try suggester(change))
    e.resync()
    return e
  }

  /// "wanted" outranks the correction "wants" in the bar; when "wants" is still what space puts in (the
  /// unfinished-word rule off), the bar shows it, in the middle.
  @Test func theBarShowsTheWordASpaceWouldPutIn() throws {
    let e = try engine("sizes we ") { $0.completionLead = .infinity }
    for k in Self.wanre { e.character(String(k.character), at: k.point) }
    #expect(e.pendingAutocorrection == "wants")
    #expect(e.suggestions().map(\.word) == ["wanre", "wants", "wanted"])
  }

  @Test func theBarKeepsItsCompletionsWhenSpaceWouldLeaveTheLetters() throws {
    let e = try engine("sizes we ")
    for k in Self.wanre { e.character(String(k.character), at: k.point) }
    #expect(e.pendingAutocorrection == nil)
    #expect(e.suggestions().map(\.word) == ["wanre", "wanted", "wants"])
  }

  @Test func afterAWordNothingIsKnownToFollowTheBarOffersTheCommonestWords() throws {
    #expect(try engine("the benchmark ").suggestions().map(\.word) == ["to", "the", "of"])
  }
}
