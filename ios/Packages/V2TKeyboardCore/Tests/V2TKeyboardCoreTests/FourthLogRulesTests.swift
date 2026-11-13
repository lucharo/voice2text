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
}
