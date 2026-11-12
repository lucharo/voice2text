import Foundation
import Testing
@testable import V2T

struct HistoryExportTests {
  let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-export-\(UUID().uuidString)")
  let older = Dictation(id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000001")!, text: "Call me back after lunch.",
                        heard: "call me back after lunch", date: Date(timeIntervalSince1970: 1_794_510_000), language: "en",
                        timings: DictationTimings(audio: 2.5, speech: 0.125, cleanup: 0.5, total: 0.75, piecesWhileRecording: 1, cleanedWhileRecording: 0))
  let newer = Dictation(id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000002")!, text: "Hola/adiós.",
                        date: Date(timeIntervalSince1970: 1_794_520_000), language: "es")

  @Test func oneDictationPerLineOldestFirstWithHeardAndTimingsOnlyWhenKept() throws {
    let data = try HistoryJSONL.make([newer, older])  // as History holds them, newest first

    #expect(String(decoding: data, as: UTF8.self) == """
      {"date":"2026-11-12T19:00:00Z","heard":"call me back after lunch","id":"6F1C2A10-0000-4000-8000-000000000001","language":"en","text":"Call me back after lunch.","timings":{"audio":2.5,"cleanedWhileRecording":0,"cleanup":0.5,"piecesWhileRecording":1,"speech":0.125,"total":0.75}}
      {"date":"2026-11-12T21:46:40Z","id":"6F1C2A10-0000-4000-8000-000000000002","language":"es","text":"Hola/adiós."}

      """)
  }

  @Test func eachLineReadsBackAsTheDictation() throws {
    let lines = String(decoding: try HistoryJSONL.make([newer, older]), as: UTF8.self).split(separator: "\n")

    let decoded = try lines.map { try JSONDecoder.v2t.decode(Dictation.self, from: Data($0.utf8)) }

    #expect(decoded == [older, newer])
  }

  @Test func theFileIsNamedForTheHistoryAndItsTime() {
    #expect(HistoryJSONL.fileName(Date(timeIntervalSince1970: 1_794_510_000)) == "v2t-history-2026-11-12T190000.jsonl")
  }

  @Test func aNewExportReplacesTheLastOne() throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("other".utf8).write(to: dir.appending(path: "v2t-keyboard-log-x.jsonl"))
    _ = try HistoryJSONL.write([older], to: dir, now: Date(timeIntervalSince1970: 1_794_510_000))

    let url = try HistoryJSONL.write([newer, older], to: dir, now: Date(timeIntervalSince1970: 1_794_510_060))

    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            == ["v2t-history-2026-11-12T190100.jsonl", "v2t-keyboard-log-x.jsonl"])
    #expect(try Data(contentsOf: url) == HistoryJSONL.make([newer, older]))
  }
}
