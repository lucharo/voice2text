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

  func dictation(_ text: String, _ timings: DictationTimings?) -> Dictation {
    Dictation(text: text, date: Date(timeIntervalSince1970: 1_000), language: "en", timings: timings)
  }

  @Test func statsNameWordsAndEachStage() {
    let d = dictation("Call me back  after\nlunch.", DictationTimings(audio: 45.2, speech: 0.08, cleanup: 1.24, total: 1.4, piecesWhileRecording: 3))

    #expect(d.stats == [
      DictationStat(symbol: "text.alignleft", text: "5 words", spoken: "5 words"),
      DictationStat(symbol: "waveform", text: "0.1 s", spoken: "speech 0.1 seconds"),
      DictationStat(symbol: "sparkles", text: "1.2 s", spoken: "cleanup 1.2 seconds"),
      DictationStat(symbol: "mic", text: "45 s", spoken: "45 seconds spoken"),
    ])
  }

  @Test func statsLeaveOutCleanupThatDidNotRun() {
    let d = dictation("Hola", DictationTimings(audio: 6.3, speech: 0.09, cleanup: nil, total: 0.1))

    #expect(d.stats == [
      DictationStat(symbol: "text.alignleft", text: "1 word", spoken: "1 word"),
      DictationStat(symbol: "waveform", text: "0.1 s", spoken: "speech 0.1 seconds"),
      DictationStat(symbol: "mic", text: "6.3 s", spoken: "6.3 seconds spoken"),
    ])
  }

  @Test func aDictationSavedBeforeTimingsShowsItsWordsOnly() {
    let d = dictation("Mañana a las nueve.", nil)

    #expect(d.stats == [DictationStat(symbol: "text.alignleft", text: "4 words", spoken: "4 words")])
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

  @Test func theWaitTicksInTenthsSinceDone() {
    let en = Locale(identifier: "en_GB"), es = Locale(identifier: "es_ES")

    let labels = [
      DictationState.transcribing.waitingLabel(elapsed: 0, locale: en),
      DictationState.cleaningUp.waitingLabel(elapsed: 0.86, locale: en),  // rounded down: never ahead of the clock
      DictationState.cleaningUp.waitingLabel(elapsed: 12.04, locale: es),
      DictationState.doneLabel(elapsed: 1.45, locale: en),
    ]

    #expect(labels == ["Transcribing 0.0 s", "Cleaning up 0.8 s", "Cleaning up 12,0 s", "Done in 1.4 s"])
  }
}

@MainActor struct TimingsExportTests {
  @Test func csvHasOneRowPerTimedDictationOldestFirstAndNoText() {
    let old = Dictation(text: "secret one", date: Date(timeIntervalSince1970: 1_793_527_200), language: "en",
                        timings: DictationTimings(audio: 45.2, speech: 0.08, cleanup: 1.24, total: 1.4, piecesWhileRecording: 3,
                                                  cleanedWhileRecording: 2))
    let untimed = Dictation(text: "before #123", date: Date(timeIntervalSince1970: 1_793_527_300), language: "en")
    let new = Dictation(text: "secret two", date: Date(timeIntervalSince1970: 1_793_527_400), language: "es",
                        timings: DictationTimings(audio: 6.3, speech: 0.09, cleanup: nil, total: 0.1))

    let csv = TimingsCSV.make([new, untimed, old])  // History keeps newest first

    #expect(csv == """
      date,language,audio_s,speech_s,cleanup_s,total_s,pieces_while_recording,cleaned_while_recording
      2026-11-01T10:00:00Z,en,45.20,0.080,1.240,1.400,3,2
      2026-11-01T10:03:20Z,es,6.30,0.090,,0.100,0,

      """)
  }

  @Test func wordEditsIgnoreCaseAndPunctuation() {
    #expect(wordEdits("um so the CAP app which was that", "So the CAP app. Which was that?") == 1)
    #expect(wordEdits("send it to me please", "Send it to me.") == 1)
    #expect(wordEdits("", "two words") == 2)
  }

  @Test func summaryTakesTheMedianOfEachModeAveragingTheMiddlePair() {
    let runs = [
      [CleanupRun(audio: 12.5, mode: "casual", seconds: 1.0, words: 10, wordsChanged: 1), CleanupRun(audio: 12.5, mode: "thorough", seconds: 2.0, words: 10, wordsChanged: 4)],
      [CleanupRun(audio: 12.5, mode: "casual", seconds: 1.2, words: 20, wordsChanged: 2), CleanupRun(audio: 12.5, mode: "thorough", seconds: 2.4, words: 20, wordsChanged: 6)],
      [CleanupRun(audio: 12.5, mode: "casual", seconds: 0.8, words: 5, wordsChanged: 0), CleanupRun(audio: 12.5, mode: "thorough", seconds: 1.6, words: 5, wordsChanged: 2)],
    ]

    #expect(CleanupComparison.summary(runs) == "casual 1.00 s, 1 words changed · thorough 2.00 s, 4 words changed")
    #expect(CleanupComparison.summary(Array(runs.prefix(2))) == "casual 1.10 s, 2 words changed · thorough 2.20 s, 5 words changed")
    #expect(CleanupComparison.csv(Array(runs.prefix(1))) == """
      dictation,audio_s,mode,cleanup_s,words,words_changed
      1,12.5,casual,1.000,10,1
      1,12.5,thorough,2.000,10,4

      """)
  }
}
