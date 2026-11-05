import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

struct ContextTests {
  let layout = KeyboardLayout(width: 402, language: .english)

  @Test func readsTheWordsBeforeTheCursor() {
    let c = TypingContext(before: "Well, I don’t know how ")
    #expect(c.words == ["Well", "I", "don't", "know", "how"])
    #expect(c.previous == "how")
    #expect(!c.sentenceStart)
  }

  @Test func aSentenceEndOrAnEmptyFieldStartsASentence() {
    #expect(TypingContext(before: "").previous == nil)
    #expect(TypingContext(before: "See you. ").sentenceStart)
    #expect(TypingContext(before: "See you.\n").previous == nil)
    #expect(TypingContext(before: "See you, ").previous == "you")
  }

  @Test func keepsOnlyTheLastFewWords() {
    let c = TypingContext(before: "one two three four five six seven eight ")
    #expect(c.words == ["three", "four", "five", "six", "seven", "eight"])
  }

  @Test func theLayoutLanguageLeadsUntilTheWordsSayOtherwise() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let prior = LanguagePrior()
    let none = prior.priors([en, es], primary: "en", context: .empty)
    #expect(none[0] == 0 && none[1] < 0)
    let spanish = prior.priors([en, es], primary: "en", context: TypingContext(before: "Hola, te quería decir que mañana "))
    #expect(spanish[1] == 0 && spanish[0] < -3)
    let english = prior.priors([en, es], primary: "es", context: TypingContext(before: "I was just telling you that "))
    #expect(english[0] == 0 && english[1] < -3)
  }

  @Test func theBuiltLexiconsCarryNextWordStatistics() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    func next(_ lex: Lexicon, _ word: String?) throws -> [String] {
      let prev = try word.map { try #require(lex.entry(of: $0)) }
      return lex.followers(of: prev).map { lex.word($0.entry) }
    }
    #expect(try next(en, "thank").first == "you")
    #expect(try next(en, "going").first == "to")
    #expect(try next(en, nil).contains("I"))
    #expect(try next(es, "por").contains("favor"))
    // the corpus's stock names (Tom, Mary) are never predicted
    for lex in [en, es] {
      for f in lex.followers(of: nil) {
        let w = lex.word(f.entry)
        #expect(w == w.lowercased() || w == "I" || w.hasPrefix("I'"), "\(w)")
      }
    }
  }

  @Test func userLexiconsHaveNoBigrams() throws {
    let lex = try Lexicon.build([("fluide", 200)], language: "en")
    #expect(lex.bigramCount == 0)
    #expect(lex.followers(of: nil).isEmpty)
  }

  /// The words the owner swiped on an iPhone 17 Pro ("hey" typed "GRU", "going" typed "govt"): abbreviations are
  /// demoted below the common words their traces resemble.
  @Test func abbreviationsNoLongerOutrankCommonWords() throws {
    let en = try Fixtures.english.get()
    for (common, abbreviation) in [("hey", "GRU"), ("going", "govt"), ("is", "USA")] {
      #expect(try #require(en.frequency(of: common)) > #require(en.frequency(of: abbreviation)) + 40, "\(common) vs \(abbreviation)")
    }
  }

  @Test func theBarPredictsTheNextWord() throws {
    let p = FakeProxy()
    p.text = "Thank "
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get(), try Fixtures.spanish.get()], layout: layout))
    e.resync()
    let bar = e.suggestions()
    #expect(bar.count == 3)
    #expect(bar[1].word == "you")  // the bold middle slot
    #expect(bar.allSatisfy { $0.kind == .prediction })
    e.pick("you")
    #expect(p.text == "Thank you ")
  }

  @Test func predictionsAreCapitalisedAtTheStartOfASentence() throws {
    let p = FakeProxy()
    p.text = "Fine. "
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: layout))
    e.resync()
    #expect(!e.suggestions().isEmpty)
    #expect(e.suggestions().allSatisfy { $0.word.first?.isUppercase == true })
  }

  @Test func noPredictionRightAfterPunctuation() throws {
    let p = FakeProxy()
    p.text = "Fine,"
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: layout))
    e.resync()
    #expect(e.suggestions().isEmpty)
  }

  @Test func theBestSwipeAlternativeTakesTheBoldMiddleSlot() {
    let p = FakeProxy()
    p.text = "how is it "
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [], layout: layout))
    e.resync()
    e.swipe(["going", "giving", "gong", "goings"])
    #expect(e.suggestions().map(\.word) == ["gong", "giving", "goings"])
  }

  @Test func theWordsBeforeASwipePickItsLanguage() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let m = MultiSwipeDecoder([en, es].map { SwipeDecoder(lexicon: $0, layout: layout) })
    var rng = SeededRandom(state: 1)
    // "see" and "se" draw the same line; the sentence decides
    let trace = try #require(syntheticTrace("see", layout: layout, jitter: 0, rng: &rng))
    #expect(m.decode(trace, context: "I will ", limit: 4).first == "see")
    #expect(m.decode(trace, context: "Mañana no ", limit: 4).first == "se")
  }
}
