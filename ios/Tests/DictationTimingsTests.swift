import Foundation
import Testing
@testable import V2T

@MainActor struct DictationTimingsTests {
  @Test func summaryNamesEachStage() {
    let t = DictationTimings(audio: 45.2, speech: 0.08, cleanup: 1.24, total: 1.4, piecesWhileRecording: 3)

    #expect(t.summary == "Ready in 1.4 s · speech 0.1 s, cleanup 1.2 s · 45 s spoken")
  }

  @Test func summaryLeavesOutCleanupThatDidNotRun() {
    let t = DictationTimings(audio: 6.3, speech: 0.09, cleanup: nil, total: 0.1)

    #expect(t.summary == "Ready in 0.1 s · speech 0.1 s · 6.3 s spoken")
  }

  @Test func historySavedBeforeTimingsStillLoads() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-timings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "history.json")
    let id = UUID()
    try Data("""
      [{"id":"\(id.uuidString)","text":"hello","date":"2026-11-01T10:00:00Z","language":"en"}]
      """.utf8).write(to: file)

    let history = History(file: file)

    #expect(history.items == [Dictation(id: id, text: "hello", date: Date(timeIntervalSince1970: 1_793_527_200), language: "en")])
  }

  @Test func timingsSurviveARelaunch() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-timings-\(UUID().uuidString)")
    let file = dir.appending(path: "history.json")
    let d = Dictation(text: "hi", date: Date(timeIntervalSince1970: 1_000), language: "en",
                      timings: DictationTimings(audio: 20, speech: 0.1, cleanup: 1.1, total: 1.3, piecesWhileRecording: 1))

    try History(file: file).add(d)

    #expect(History(file: file).items == [d])
  }

  @Test func theKeyboardNamesEachStageAfterDone() {
    #expect([DictationState.transcribing, .cleaningUp].map(\.waitingLabel) == ["Transcribing…", "Cleaning up…"])
  }
}
