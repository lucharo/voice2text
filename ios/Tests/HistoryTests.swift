import Foundation
import Testing
@testable import V2T

@MainActor struct HistoryTests {
  let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-history-\(UUID().uuidString)")
  var file: URL { dir.appending(path: "history.json") }

  func dictation(_ text: String, _ seconds: TimeInterval) -> Dictation {
    Dictation(id: UUID(), text: text, date: Date(timeIntervalSince1970: seconds), language: "en")
  }

  @Test func startsEmptyWithoutAFile() {
    let history = History(file: file)

    #expect(history.items == [])
  }

  @Test func keepsNewestFirstAcrossARelaunch() throws {
    let first = dictation("first", 1_000), second = dictation("second", 2_000)
    let history = History(file: file)

    try history.add(first)
    try history.add(second)

    #expect(History(file: file).items == [second, first])
  }

  @Test func deleteRemovesOnlyThatDictationAndPersists() throws {
    let keep = dictation("keep", 1_000), drop = dictation("drop", 2_000)
    let history = History(file: file)
    try history.add(keep)
    try history.add(drop)

    try history.delete(drop.id)

    #expect(History(file: file).items == [keep])
  }

  @Test func unreadableFileStartsEmptyAndIsKeptAside() throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: file)

    let history = History(file: file)

    #expect(history.items == [])
    #expect(!FileManager.default.fileExists(atPath: file.path()))
    #expect(try String(contentsOf: file.appendingPathExtension("unreadable"), encoding: .utf8) == "not json")
  }

  @Test func clearDeletesEveryDictationAndTheFile() throws {
    let history = History(file: file)
    try history.add(dictation("one", 1_000))
    try history.add(dictation("two", 2_000))

    try history.clear()

    #expect(history.items == [])
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
    #expect(History(file: file).items == [])
  }

  /// A file that cannot be removed leaves the list as it is on disk, so Clear History can be tried again.
  @Test func aFailedClearKeepsEveryDictation() throws {
    let history = History(file: file)
    let one = dictation("one", 1_000)
    try history.add(one)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

    #expect(throws: (any Error).self) { try history.clear() }

    #expect(history.items == [one])
  }

  @Test func bytesIsZeroWithoutAFileAndGrowsWithDictations() throws {
    let history = History(file: file)
    #expect(history.bytes == 0)

    try history.add(dictation("a sentence someone said", 1_000))

    #expect(history.bytes > 0)
  }
}
