import Foundation
import Testing
@testable import V2T

struct PersonalDictionaryTests {
  func dictionary(_ text: String) throws -> PersonalDictionary {
    let file = FileManager.default.temporaryDirectory.appending(path: "v2t-dict-\(UUID().uuidString).txt")
    let d = PersonalDictionary(file: file)
    try d.save(text)
    return d
  }

  @Test func parsesTermsAndReplacementsLikeTheMacApp() throws {
    let d = try dictionary("# comment\nClaude\n\nvoice to text => voice2text\n  Fluide  \n=> nothing\nbad =>\n")
    #expect(d.entries.terms == ["Claude", "Fluide"])
    #expect(d.entries.replacements.map { "\($0.heard)|\($0.written)" } == ["voice to text|voice2text"])
  }

  @Test func replacementsAreWholeWordAndCaseInsensitive() throws {
    let d = try dictionary("v two t => v2t\nai => AI\n")
    #expect(d.applyReplacements("V two T beats said ai, not maid") == "v2t beats said AI, not maid")
  }

  /// iCloud sync keeps one line per heard side (and per term, ignoring case), so dictation uses only that one too:
  /// a downloaded copy then turns the same words into the same text.
  @Test func aSecondLineForTheSameHeardSideOrTermIsIgnored() throws {
    let d = try dictionary("ai => AI\nAI => A.I.\nClaude\nclaude\n")

    #expect(d.applyReplacements("said ai") == "said AI")
    #expect(d.entries.terms == ["Claude"])
    #expect(d.entries.replacements.map { "\($0.heard)|\($0.written)" } == ["ai|AI"])
  }

  @Test func keyboardWordsCoverTermsAndWrittenSides() throws {
    let d = try dictionary("Claude Code\nfluid => Fluide\n")
    #expect(d.keyboardWords == ["Claude", "Code", "Fluide"])
  }

  @Test func addingWritesTheMacFormatAndKeepsComments() throws {
    let d = try dictionary("# mine\nClaude\n")
    try d.addTerm("  Fluide ")
    try d.addReplacement(heard: "v two t", written: "v2t")
    #expect(d.text == "# mine\nClaude\nFluide\nv two t => v2t\n")
    #expect(PersonalDictionary(file: d.file).items.map(\.line) == ["Claude", "Fluide", "v two t => v2t"])
  }

  /// The app holds one copy for its lifetime while the keyboard adds terms to the same file: an edit in the
  /// app keeps the keyboard's term, and a reload shows it.
  @Test func anEditKeepsTermsAnotherCopyAdded() throws {
    let app = try dictionary("Claude\n")
    let keyboard = PersonalDictionary(file: app.file)
    try keyboard.addTerm("marimo")
    try app.addTerm("Fluide")
    #expect(app.terms == ["Claude", "marimo", "Fluide"])
    try keyboard.addTerm("Kian")
    app.reload()
    #expect(app.terms == ["Claude", "marimo", "Fluide", "Kian"])
  }

  /// "Edit as text" left open while the keyboard adds a word: closing it unchanged writes nothing, and an
  /// edited draft keeps the keyboard's word.
  @Test func theTextEditorKeepsWordsAddedWhileItWasOpen() throws {
    let app = try dictionary("Claude\n")
    let snapshot = app.text
    try PersonalDictionary(file: app.file).addTerm("marimo")
    try app.saveEdit(snapshot, from: snapshot)
    #expect(PersonalDictionary(file: app.file).terms == ["Claude", "marimo"])
    try PersonalDictionary(file: app.file).addTerm("Kian")
    try app.saveEdit("Claude\nFluide\n", from: snapshot)
    #expect(PersonalDictionary(file: app.file).terms == ["Claude", "Fluide", "marimo", "Kian"])
  }

  /// Writers on separate copies at the same time each keep their word (NSFileCoordinator serialises them).
  @Test func concurrentAddsFromSeparateCopiesAllLand() async throws {
    let file = try dictionary("").file
    let words = (0..<20).map { "word\($0)" }
    await withTaskGroup(of: Void.self) { group in
      for w in words { group.addTask { try? PersonalDictionary(file: file).addTerm(w) } }
    }
    #expect(Set(PersonalDictionary(file: file).terms) == Set(words))
  }

  @Test func addingRefusesEmptyArrowsAndDuplicates() throws {
    let d = try dictionary("Claude\nai => AI\n")
    #expect(throws: PersonalDictionary.EntryError.empty) { try d.addTerm("  ") }
    #expect(throws: PersonalDictionary.EntryError.arrow) { try d.addTerm("a => b") }
    #expect(throws: PersonalDictionary.EntryError.duplicate) { try d.addTerm("claude") }
    #expect(throws: PersonalDictionary.EntryError.duplicate) { try d.addReplacement(heard: "AI", written: "A.I.") }
    #expect(throws: PersonalDictionary.EntryError.empty) { try d.addReplacement(heard: "x", written: "") }
    #expect(d.text == "Claude\nai => AI\n")
  }

  @Test func removingDropsOnlyThatLine() throws {
    let d = try dictionary("# keep\nClaude\nai=>AI\nFluide\n")
    try d.remove("ai=>AI")
    #expect(d.text == "# keep\nClaude\nFluide\n")
    #expect(PersonalDictionary(file: d.file).terms == ["Claude", "Fluide"])
  }

  @Test(arguments: ["\r\n", "\r"])
  func removingWorksWhateverTheLineEndings(eol: String) throws {
    let d = try dictionary(["# keep", "Claude", "ai => AI", "Fluide", ""].joined(separator: eol))
    try d.remove("ai => AI")
    #expect(d.items.map(\.line) == ["Claude", "Fluide"])
  }

  @Test func dictionaryWordsAreExcludedFromAutocorrectInLowercase() throws {
    let d = try dictionary("Teh\nClaude Code\nfluid => Fluide\n")
    #expect(d.autocorrectExclusions == ["teh", "claude", "code", "fluide"])
    #expect(try dictionary("Teh-Code\nO'Neil\n").autocorrectExclusions == ["teh", "code", "o'neil"])
  }

  @Test func survivesARelaunch() throws {
    let d = try dictionary("Claude\n")
    #expect(PersonalDictionary(file: d.file).terms == ["Claude"])
  }
}
