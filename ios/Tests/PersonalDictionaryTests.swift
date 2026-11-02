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

  @Test func keyboardWordsCoverTermsAndWrittenSides() throws {
    let d = try dictionary("Claude Code\nfluid => Fluide\n")
    #expect(d.keyboardWords == ["Claude", "Code", "Fluide"])
  }

  @Test func survivesARelaunch() throws {
    let d = try dictionary("Claude\n")
    #expect(PersonalDictionary(file: d.file).terms == ["Claude"])
  }
}
