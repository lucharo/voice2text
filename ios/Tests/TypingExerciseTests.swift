import Foundation
import Testing
import V2TKeyboardCore
@testable import V2T

/// A clock the test moves by hand.
final class ExerciseClock: @unchecked Sendable {
  var now: TimeInterval = 1000
}

@MainActor struct TypingExerciseTests {
  let dir = FileManager.default.temporaryDirectory.appending(path: "exercise-\(UUID().uuidString)")
  let sentences = [ExerciseSentences.Sentence(id: "en-01", text: "Can you grab some milk?"),
                   ExerciseSentences.Sentence(id: "en-02", text: "I’m late, sorry!")]

  func lines(_ file: String = TypingExerciseLog.fileName) -> [NSDictionary] {
    let text = (try? String(contentsOf: dir.appending(path: file), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? NSDictionary ?? ["unparsable": String($0)] }
  }

  @Test func eachSentenceIsOneLineWithWhatWasAskedAndTyped() {
    let clock = ExerciseClock()
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    let session = TypingExerciseSession(sentences: sentences, directory: dir, clock: { clock.now }, now: { wall }, recording: { true })

    session.shown()
    clock.now = 1004.25
    session.next(typed: "Can you grab some mikl?")

    #expect(lines() == [["t": 1_000_000, "e": "exercise", "end": 1_004_250, "wall": "2027-01-15T08:00:00Z",
                         "id": "en-01", "target": "Can you grab some milk?", "typed": "Can you grab some mikl?"] as NSDictionary])
  }

  @Test func timesAreOnTheKeyboardLogsClock() {
    let session = TypingExerciseSession(sentences: sentences, directory: dir, recording: { true })
    let before = ProcessInfo.processInfo.systemUptime * 1000

    session.shown()
    session.next(typed: "x")

    let after = ProcessInfo.processInfo.systemUptime * 1000
    let t = lines().first?["t"] as? Double ?? -1, end = lines().first?["end"] as? Double ?? -1
    #expect(before - 1 <= t && t <= end && end <= after + 1, "t \(t) end \(end) outside \(before)...\(after)")
  }

  @Test func nothingIsRecordedWhileTheLogIsOff() {
    let session = TypingExerciseSession(sentences: sentences, directory: dir, recording: { false })

    session.shown()
    session.next(typed: "x")

    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: TypingExerciseLog.fileName).path))
    #expect(session.index == 1)
  }

  @Test func clearLogDeletesTheExercises() {
    TypingExerciseLog.append(.init(id: "en-01", target: "a", typed: "a", start: 1, end: 2, wall: Date()), in: dir)

    KeyboardDebugLog.clear(in: dir)

    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: TypingExerciseLog.fileName).path))
    #expect(KeyboardDebugLog.size(in: dir) == 0)
  }

  @Test func exportJoinsTheExercisesAfterTheKeyboardsLines() throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"t\":1,\"e\":\"key\",\"text\":\"a\"}\n".utf8).write(to: dir.appending(path: KeyboardDebugLog.fileName))
    TypingExerciseLog.append(.init(id: "en-01", target: "a", typed: "a", start: 0.5, end: 2, wall: Date(timeIntervalSince1970: 0)), in: dir)

    let exported = String(decoding: try KeyboardDebugLog.merged(in: dir), as: UTF8.self)

    #expect(exported == "{\"t\":1,\"e\":\"key\",\"text\":\"a\"}\n"
      + "{\"t\":500,\"e\":\"exercise\",\"end\":2000,\"wall\":\"1970-01-01T00:00:00Z\",\"id\":\"en-01\",\"target\":\"a\",\"typed\":\"a\"}\n")
  }

  @Test func pastItsSizeTheFileMovesAsideSoTwoAtMostAreKept() {
    let entry = TypingExerciseLog.Entry(id: "en-01", target: "a", typed: "a", start: 1, end: 2, wall: Date())
    let size = TypingExerciseLog.line(entry).utf8.count

    for _ in 0..<5 { TypingExerciseLog.append(entry, in: dir, maxFileBytes: 2 * size) }

    // as the keyboard's log: the line that takes a file past its size moves it aside (the third), and the
    // fourth and fifth start a new one
    #expect((lines(TypingExerciseLog.rotatedName).count, lines().count) == (3, 2))
  }

  @Test func wordsAreComparedInOrderWithoutTheirPunctuation() {
    #expect(TypingExerciseLog.wrongWords(target: "I’m late, sorry!", typed: "I'm late sorry").isEmpty)
    #expect(TypingExerciseLog.wrongWords(target: "She's back from Lisbon.", typed: "She's back form lisbon").map { [$0.target, $0.typed] }
      == [["from", "form"], ["Lisbon", "lisbon"]])
  }

  @Test func aSentenceWithWordsMissingIsOnePair() {
    #expect(TypingExerciseLog.wrongWords(target: "Sit by the window.", typed: "Sit bythe window").map { [$0.target, $0.typed] }
      == [["Sit by the window.", "Sit bythe window"]])
  }

  @Test func theSummaryCountsWrongWordsAndCharactersPerSecond() {
    let clock = ExerciseClock()
    let session = TypingExerciseSession(sentences: sentences, directory: dir, clock: { clock.now }, recording: { false })

    session.shown()
    clock.now = 1001
    session.edited()
    clock.now = 1002
    session.edited()  // only the first change starts the time
    clock.now = 1005
    session.next(typed: "Can you grab some mikl?")  // 23 characters in 4 s
    session.shown()
    clock.now = 1010
    session.edited()
    clock.now = 1012
    session.next(typed: "I'm late, sorry!")  // 16 in 2 s

    #expect(session.finished)
    #expect(session.wrongWords.map { [$0.target, $0.typed] } == [["milk", "mikl"]])
    #expect(session.charactersPerSecond == 39.0 / 6)
  }
}
