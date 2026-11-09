import Foundation
import Testing
@testable import V2T

/// A model that "cleans" by upper-casing, remembering what it was asked; `refuse` makes it not answer.
private actor Model {
  var asked: [String] = []
  var refuse: Set<String> = []
  func setRefuse(_ s: Set<String>) { refuse = s }
  func clean(_ text: String) -> (text: String, answered: Bool) {
    asked.append(text)
    return refuse.contains(text) ? (text, false) : (text.uppercased(), true)
  }
}

/// A model that holds its answer for `held` until `release()`, to put Stop in the middle of a request.
private actor HeldModel {
  let held: String
  var asked: [String] = []
  private var gate: CheckedContinuation<Void, Never>?
  init(held: String) { self.held = held }
  func clean(_ text: String) async -> (text: String, answered: Bool) {
    asked.append(text)
    if text == held { await withCheckedContinuation { gate = $0 } }
    return (text.uppercased(), true)
  }
  func release() { gate?.resume(); gate = nil }
  var isHolding: Bool { gate != nil }
}

@MainActor struct LiveCleanupTests {
  @Test func stopDuringARequestKeepsItsAnswerAndCleansTheQueuedSegmentWithTheRest() async {
    let model = HeldModel(held: "one two three. four five six.")
    let live = LiveCleanup(terms: [], minimumWords: 3) { text, _ in await model.clean(text) }
    live.offer(pieces: ["one two three. four", "five six. seven"])
    while !(await model.isHolding) { await Task.yield() }  // the first segment is with the model
    live.offer(pieces: ["one two three. four", "five six. seven", "eight nine. ten"])  // the second waits its turn

    live.stop()
    await model.release()
    let result = await live.finish("one two three. four five six. seven eight nine. ten", terms: [])

    // the request under way at Stop is kept; the queued segment was never sent and goes with the tail
    #expect(await model.asked == ["one two three. four five six.", "seven eight nine. ten"])
    #expect(result.text == "ONE TWO THREE. FOUR FIVE SIX. SEVEN EIGHT NINE. TEN")
    #expect(result.cleanedWhileRecording == 1)
  }

  @Test func settledSentencesAreCleanedWhileRecordingAndOnlyTheRestAfterStop() async {
    let model = Model()
    let live = LiveCleanup(terms: ["Claude"], minimumWords: 3) { text, _ in await model.clean(text) }

    live.offer(pieces: ["so the plan is fine. we ship it on"])  // "fine." ends inside the piece
    live.offer(pieces: ["so the plan is fine. we ship it on", "monday. then we rest"])
    await live.idle()  // the recording goes on long enough for both to be cleaned
    let result = await live.finish("so the plan is fine. we ship it on monday. then we rest", terms: ["Claude"])

    #expect(await model.asked == ["so the plan is fine.", "we ship it on monday.", "then we rest"])
    #expect(result.text == "SO THE PLAN IS FINE. WE SHIP IT ON MONDAY. THEN WE REST")
    #expect(result.cleanedWhileRecording == 2)
  }

  @Test func aSegmentTheModelDidNotAnswerIsCleanedAgainAfterStop() async {
    let model = Model()
    await model.setRefuse(["one two three."])  // rate-limited in the background
    let live = LiveCleanup(terms: [], minimumWords: 3) { text, _ in await model.clean(text) }

    live.offer(pieces: ["one two three. four", "five six"])
    await live.idle()
    let result = await live.finish("one two three. four five six", terms: [])

    #expect(await model.asked == ["one two three.", "one two three. four five six"])
    #expect(result.cleanedWhileRecording == 0)
  }

  @Test func onlyTheSegmentsTheModelMissedAreCleanedAgainAndTheRestAreKept() async {
    let model = Model()
    await model.setRefuse(["one two three. four five six."])
    let live = LiveCleanup(terms: [], minimumWords: 3) { text, _ in await model.clean(text) }

    live.offer(pieces: ["one two three. four", "five six. seven"])
    live.offer(pieces: ["one two three. four", "five six. seven", "eight nine. ten"])
    await live.idle()
    let result = await live.finish("one two three. four five six. seven eight nine. ten", terms: [])

    // the first segment failed in the background and is retried alone; the second is kept; then the tail
    #expect(await model.asked == ["one two three. four five six.", "seven eight nine.", "one two three. four five six.", "ten"])
    #expect(result.text == "one two three. four five six. SEVEN EIGHT NINE. TEN")  // the retry was refused too
    #expect(result.cleanedWhileRecording == 1)
  }

  @Test func segmentsStillQueuedAtStopAreCleanedWithTheRestInOneRequest() async {
    let model = Model()
    let live = LiveCleanup(terms: [], minimumWords: 3) { text, _ in await model.clean(text) }
    live.offer(pieces: ["one two three. four", "five six. seven"])
    live.offer(pieces: ["one two three. four", "five six. seven", "eight nine. ten"])

    // Stop comes before either segment reached the model; the tail is then transcribed before finish
    live.stop()
    await Task.yield()
    let result = await live.finish("one two three. four five six. seven eight nine. ten", terms: [])

    #expect(await model.asked == ["one two three. four five six. seven eight nine. ten"])
    #expect(result.cleanedWhileRecording == 0)
  }

  @Test func newDictionaryTermsOrAnotherTranscriptMeanCleanEverythingNow() async {
    let model = Model()
    let live = LiveCleanup(terms: [], minimumWords: 3) { text, _ in await model.clean(text) }
    live.offer(pieces: ["one two three. four", "five"])

    let result = await live.finish("one two three. four five", terms: ["marimo"])

    // the segment still queued is cancelled before it reaches the model: no wait for work that can't be used
    #expect(await model.asked == ["one two three. four five"])
    #expect(result.text == "ONE TWO THREE. FOUR FIVE" && result.cleanedWhileRecording == 0)
  }

  @Test func nothingSettledIsJustOneCleanupAfterStop() async {
    let model = Model()
    let live = LiveCleanup(terms: [], minimumWords: 30) { text, _ in await model.clean(text) }
    live.offer(pieces: ["a short note. that is all"])

    let result = await live.finish("a short note. that is all", terms: [])

    #expect(await model.asked == ["a short note. that is all"])
    #expect(result.cleanedWhileRecording == 0)
  }
}
