import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// The rules a fourth typing log asked for (iPhone 17 Pro, 402 pt wide, English and Spanish on, builds 1.1 (124)
/// and (127)), each on the touches the log recorded, with a control: with the rule off, the old answer comes back.
struct FourthLogRulesTests {
  static let layout = KeyboardLayout(width: 402, language: .english)

  static func keys(_ touches: [(Character, Double, Double)]) -> [TypedKey] { touches.map { TypedKey($0.0, at: CGPoint(x: $0.1, y: $0.2)) } }

  func suggester(_ change: (Suggester) -> Void = { _ in }) throws -> Suggester {
    let s = Suggester(lexicons: [try Fixtures.english.get(), try Fixtures.spanish.get()], layout: Self.layout)
    change(s)
    return s
  }

  // MARK: language

  // "Can u sho" (show)
  static let sho = keys([("s", 71.3, 88.3), ("h", 241, 76), ("o", 339.7, 20.7)])

  /// One short word that is Spanish ("u", "te", "o", "le", "e") after English ones: the bar's next words stay
  /// English. The second list is what the bar offered before.
  @Test(arguments: [("Can u ", ["otra", "otros", "otro"]), ("Oki u ", ["otra", "otros", "otro"]), ("for te ", ["gusta", "gustaría", "lo"]),
                    ("back o ", ["no", "menos", "en"]), ("I'd le ", ["gusta", "dijo", "dio"]), ("this e ", ["inglés", "inteligente", "hijos"])])
  func oneShortSpanishWordDoesNotTurnTheNextWordsSpanish(before: String, spanish: [String]) throws {
    let context = TypingContext(before: before)
    #expect(try suggester().predictions(context: context).map(\.word) == ["the", "to", "of"])
    #expect(try suggester { $0.languagePrior.shortWordCap = .infinity; $0.followerLanguageGap = .infinity }
      .predictions(context: context).map(\.word) == spanish)
  }

  @Test func oneShortSpanishWordDoesNotTurnTheCompletionsSpanish() throws {
    let context = TypingContext(before: "Can u ")
    #expect(try suggester().suggestions(for: Self.sho, context: context).map(\.word) == ["show", "short", "sho"])
    #expect(try suggester { $0.languagePrior.shortWordCap = .infinity; $0.followerLanguageGap = .infinity }
      .suggestions(for: Self.sho, context: context).map(\.word) == ["ahora", "hombres", "sho"])
  }

  /// A Spanish sentence, and two Spanish words after English ones, still get Spanish next words.
  @Test(arguments: [("dame un ", ["poco", "buen", "hombre"]), ("quiero que me ", ["gusta", "gustaría", "dijo"]),
                    ("I told her que te ", ["gusta", "gustaría", "lo"])])
  func spanishWordsStillGetSpanishNextWords(before: String, expected: [String]) throws {
    #expect(try suggester().predictions(context: TypingContext(before: before)).map(\.word) == expected)
  }

  /// A single letter moves the language by at most `shortWordCap`; a longer word by all it weighs.
  @Test func aSingleLetterWeighsLittleInTheLanguageOfTheContext() throws {
    let s = try suggester()
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let capped = s.languagePrior.capShortWord("u", [-13, -4.5])
    #expect(capped == [-5.5, -4.5])
    #expect(s.languagePrior.capShortWord("te", [-13, -4.9]) == [-13, -4.9])
    #expect(s.languagePrior.priors([en, es], primary: "en", context: TypingContext(before: "Can u ")).first == 0)
  }

  // MARK: space

  // "[needsme]" and "Weneed", typed without the space
  static let needsme = keys([("n", 280.3, 140.3), ("e", 90.7, 10), ("e", 93.3, 27.7), ("d", 121.3, 83.3), ("s", 70.7, 74), ("m", 331, 128), ("e", 95, 20)])
  static let weneed = keys([("W", 61.3, 34.3), ("e", 113.7, 37.7), ("n", 282, 146.7), ("e", 108, 19), ("e", 100.7, 21.3), ("d", 135.3, 74)])

  @Test(arguments: [(needsme, "[", "needs me", "needs"), (weneed, "", "We need", "Weened")])
  func aSpaceLeftOutIsPutBack(typed: [TypedKey], before: String, expected: String, without: String) throws {
    let context = TypingContext(before: before)
    #expect(try suggester().autocorrection(for: typed, context: context) == expected)
    #expect(try suggester { $0.missingSpacePenalty = .infinity }.autocorrection(for: typed, context: context) == without)
  }

  /// The bar shows the two words in its middle slot, as the word a space would put in.
  @Test func theBarOffersTheTwoWords() throws {
    let e = TypingEngine(proxy: FakeProxy(), suggester: try suggester())
    e.resync()
    for k in Self.weneed { e.character(String(k.character), at: k.point) }
    #expect(e.suggestions().map(\.word)[1] == "We need")
  }

  // MARK: compound

  // "changelog": "chan" is what delete left of the correction "channel" (no touches), then g, e, l, o, g
  static let changelog = "chan".map { TypedKey($0) } + keys([("g", 203, 74), ("e", 99.3, 33), ("l", 358.3, 75.3), ("o", 350.3, 16.3), ("g", 185.7, 91.7)])

  @Test func twoWordsThatAreNotAPairAreLeftAsTyped() throws {
    let context = TypingContext(before: "readable ")
    #expect(try suggester().autocorrection(for: Self.changelog, context: context) == nil)
    #expect(try suggester { $0.compoundFloor = -.infinity }.autocorrection(for: Self.changelog, context: context) == "changeling")
  }
}
