import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// The suggester keeps the last word's search and ranking, so each key carries on from the one before. What it
/// answers must be what a suggester that never saw the earlier keys answers.
struct SuggesterSearchTests {
  let layout = KeyboardLayout(width: 402, language: .english)

  func lexicons() throws -> [Lexicon] { [try Fixtures.english.get(), try Fixtures.spanish.get()] }

  /// Words typed a key at a time with touches off the key centres. On the way a wrong fourth key, then the
  /// right one in its place (the same number of keys, the last one another), then two keys fewer, so the search
  /// starts again from a changed key and steps back as well as forward.
  @Test(arguments: ["collaborative", "becuase", "hvent", "tomorow", "wouldn't", "particular", "som", "standford", "cancion"])
  func aSearchCarriedOnFromTheLastKeyFindsWhatAFreshSearchFinds(word: String) throws {
    let lexicons = try lexicons()
    let carried = Suggester(lexicons: lexicons, layout: layout)
    var rng = SeededRandom(state: 7)
    let context = TypingContext(before: "I think the ")
    let keys = noisyTaps(word, layout, std: 0.25, rng: &rng)
    let slip = TypedKey("q", at: try #require(layout.keys.first { $0.label == "q" }).center)
    var steps = (1...3).map { Array(keys.prefix($0)) }
    steps += [Array(keys.prefix(3)) + [slip], Array(keys.prefix(min(4, keys.count))), Array(keys.prefix(2))]
    steps += (3...keys.count).map { Array(keys.prefix($0)) }
    for typed in steps {
      let fresh = Suggester(lexicons: lexicons, layout: layout)
      #expect(carried.suggestions(for: typed, context: context, limit: 10) == fresh.suggestions(for: typed, context: context, limit: 10))
      #expect(carried.autocorrection(for: typed, context: context) == fresh.autocorrection(for: typed, context: context))
    }
  }

  /// Each language has its own beam: what English finds is what it finds alone, however many near misses
  /// Spanish has for the same touches.
  @Test(arguments: ["becuase", "catapiller", "collaborative", "particular"])
  func aSecondLanguageLeavesTheFirstsSearchAsItWas(word: String) throws {
    let lexicons = try lexicons()
    let typed = taps(word, layout)
    let alone = Suggester(lexicons: [lexicons[0]], layout: layout).search(typed).map { "\(String(decoding: $0.prefix, as: UTF8.self)) \($0.cost)" }
    let both = Suggester(lexicons: lexicons, layout: layout).search(typed).filter { $0.lex == 0 }.map { "\(String(decoding: $0.prefix, as: UTF8.self)) \($0.cost)" }
    #expect(!alone.isEmpty)
    #expect(both == alone)
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
