import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// The suggester keeps the last word's search and ranking, so each key carries on from the one before. What it
/// answers must be what a suggester that never saw the earlier keys answers.
struct SuggesterSearchTests {
  let layout = KeyboardLayout(width: 402, language: .english)

  func lexicons() throws -> [Lexicon] { [try Fixtures.english.get(), try Fixtures.spanish.get()] }

  /// Words typed a key at a time with touches off the key centres, and on the way a wrong key that is deleted
  /// together with the letter before it, so the search steps back two letters and then forward again.
  @Test(arguments: ["collaborative", "becuase", "hvent", "tomorow", "wouldn't", "particular", "som", "standford", "cancion"])
  func aSearchCarriedOnFromTheLastKeyFindsWhatAFreshSearchFinds(word: String) throws {
    let lexicons = try lexicons()
    let carried = Suggester(lexicons: lexicons, layout: layout)
    var rng = SeededRandom(state: 7)
    let context = TypingContext(before: "I think the ")
    let keys = noisyTaps(word, layout, std: 0.25, rng: &rng)
    var steps = (1...keys.count).map { Array(keys.prefix($0)) }
    let slip = TypedKey("q", at: try #require(layout.keys.first { $0.label == "q" }).center)
    steps.insert(contentsOf: [Array(keys.prefix(3)) + [slip], Array(keys.prefix(3)), Array(keys.prefix(2))], at: 3)
    for typed in steps {
      let fresh = Suggester(lexicons: lexicons, layout: layout)
      #expect(carried.suggestions(for: typed, context: context, limit: 10) == fresh.suggestions(for: typed, context: context, limit: 10))
      #expect(carried.autocorrection(for: typed, context: context) == fresh.autocorrection(for: typed, context: context))
    }
  }

  @Test func theSameLettersAfterOtherWordsAreRankedAgain() throws {
    let lexicons = try lexicons()
    let carried = Suggester(lexicons: lexicons, layout: layout)
    let typed = taps("s", layout)
    for before in ["I got ", "Creo que el ", ""] {
      let context = TypingContext(before: before)
      let fresh = Suggester(lexicons: lexicons, layout: layout)
      #expect(carried.suggestions(for: typed, context: context, limit: 10) == fresh.suggestions(for: typed, context: context, limit: 10))
    }
  }

  @Test func aChangedWeightIsNotAnsweredFromTheLastSearch() throws {
    let lexicons = try lexicons()
    let carried = Suggester(lexicons: lexicons, layout: layout)
    let typed = taps("becuase", layout)
    _ = carried.suggestions(for: typed, limit: 10)
    carried.editPenalty = 1
    carried.frequencyWeight = 2
    let fresh = Suggester(lexicons: lexicons, layout: layout)
    fresh.editPenalty = 1
    fresh.frequencyWeight = 2
    #expect(carried.suggestions(for: typed, limit: 10) == fresh.suggestions(for: typed, limit: 10))
  }

  @Test func otherWordListsAreNotAnsweredFromTheLastSearch() throws {
    let lexicons = try lexicons()
    let carried = Suggester(lexicons: lexicons, layout: layout)
    let typed = taps("cancion", layout)
    _ = carried.suggestions(for: typed, limit: 10)
    carried.lexicons = [lexicons[0]]
    #expect(carried.suggestions(for: typed, limit: 10) == Suggester(lexicons: [lexicons[0]], layout: layout).suggestions(for: typed, limit: 10))
  }

  /// The table of the commonest words after one and two letters against a scan of the whole range.
  @Test(arguments: ["c", "co", "t", "th", "wh", "q", "zz", "s", "st"])
  func theCommonestWordsAfterOneOrTwoLettersAreTheOnesAFullScanFinds(prefix: String) throws {
    for lex in try lexicons() {
      let p = Array(prefix.utf8)
      var want: [(Int, Int)] = []
      for i in lex.prefixRange(p) where lex.keyLength(i) > p.count && lex.frequency(i) > 0 { want.append((i, lex.frequency(i))) }
      want.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
      #expect(lex.commonest(after: p).map(\.0) == want.prefix(3).map(\.0), "\(lex.language) \(prefix)")
    }
  }

  @Test func prefixesTheTableDoesNotHoldHaveNoCommonestWords() throws {
    let lex = try Fixtures.english.get()
    #expect(lex.commonest(after: []).isEmpty)
    #expect(lex.commonest(after: Array("the".utf8)).isEmpty)
  }
}
