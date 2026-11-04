import Foundation
import Testing
@testable import V2TKeyboardCore

struct LexiconTests {
  let small = try! Lexicon.build([("como", 200), ("cómo", 180), ("comer", 150), ("don't", 220), ("año", 190), ("ano", 60), ("zz", 0)], language: "es")

  func words(_ r: Range<Int>, _ lex: Lexicon) -> [String] { r.map { lex.word($0) } }

  @Test func foldsAccentsEnyeApostrophesAndCase() {
    #expect(Lexicon.fold("Don't") == Array("dont".utf8))
    #expect(Lexicon.fold("AÑO") == Array("ano".utf8))
    #expect(Lexicon.fold("cómo-sí") == Array("comosi".utf8))
  }

  @Test func exactRangeListsEveryWordOfAKeyCommonestFirst() {
    #expect(words(small.exactRange(Array("como".utf8)), small) == ["como", "cómo"])
    #expect(words(small.exactRange(Array("ano".utf8)), small) == ["año", "ano"])
  }

  @Test func prefixRangeListsCompletionsInKeyOrder() {
    #expect(words(small.prefixRange(Array("com".utf8)), small) == ["comer", "como", "cómo"])
  }

  @Test func missingPrefixIsAnEmptyRange() {
    #expect(small.prefixRange(Array("xq".utf8)).isEmpty)
  }

  @Test func zeroFrequencyWordsStayButAreMarkedUnsuggestible() {
    let i = small.exactRange(Array("zz".utf8)).lowerBound
    #expect(small.word(i) == "zz")
    #expect(small.frequency(i) == 0)
  }

  @Test func rejectsAFileThatIsNotALexicon() {
    #expect(throws: Lexicon.FormatError.self) { try Lexicon(data: Data("nope, not a lexicon".utf8), language: "en") }
  }

  @Test func realEnglishListFindsCommonWordsAndContractions() throws {
    let en = try Fixtures.english.get()
    #expect(en.count > 150_000)
    #expect(words(en.exactRange(Array("dont".utf8)), en).contains("don't"))
    #expect(words(en.exactRange(Array("the".utf8)), en).first == "the")
  }

  @Test func realSpanishListPutsAccentedFormsUnderTheirTypedKey() throws {
    let es = try Fixtures.spanish.get()
    #expect(es.count > 200_000)
    let cancion = words(es.exactRange(Array("cancion".utf8)), es)
    #expect(cancion.contains("canción"))
    #expect(words(es.exactRange(Array("ano".utf8)), es).contains("año"))
  }
}
