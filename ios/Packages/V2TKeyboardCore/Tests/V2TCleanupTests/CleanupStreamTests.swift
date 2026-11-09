import Testing
@testable import V2TCleanup

@Suite struct CleanupStreamTests {
  @Test func aSegmentEndsAtTheLastSentenceEndInsideAPiece() {
    var stream = CleanupStream(minimumWords: 3)

    let segment = stream.next(pieces: ["So the plan is fine. We ship it on", "Monday. Then we rest."])

    // "Monday." ends inside the second piece; "rest." ends a piece, where a cut may have put the full stop
    #expect(segment == "So the plan is fine. We ship it on Monday.")
    #expect(stream.takenWords == 10)
  }

  @Test func aFullStopAtAPieceEndIsNeverASegmentEnd() {
    var stream = CleanupStream(minimumWords: 1)

    // the cut fell mid-sentence and the model closed the piece anyway: cleanup must see both sides
    #expect(stream.next(pieces: ["or the CAP app."]) == nil)
    #expect(stream.next(pieces: ["or the CAP app.", "Which was that one. And"]) == "or the CAP app. Which was that one.")
  }

  @Test func shortSettledTextWaitsForMore() {
    var stream = CleanupStream(minimumWords: 10)

    #expect(stream.next(pieces: ["Short one. And then", "more"]) == nil)
    #expect(stream.takenWords == 0)
  }

  @Test func laterSegmentsFollowTheFirstAndTheRestIsWhatRemains() {
    var stream = CleanupStream(minimumWords: 2)
    let first = stream.next(pieces: ["One two. Three", "four. Five"])
    let second = stream.next(pieces: ["One two. Three", "four. Five", "six seven. Eight"])

    let rest = stream.rest(of: "One two. Three four. Five six seven. Eight nine.")

    #expect([first, second, rest] == ["One two. Three four.", "Five six seven.", "Eight nine."])
  }

  @Test func aDifferentFinalTextMeansCleanItAll() {
    var stream = CleanupStream(minimumWords: 1)
    _ = stream.next(pieces: ["Hello there. And", "more"])

    // a piece failed and the whole recording was decoded again, with other words
    #expect(stream.rest(of: "Hello, there. And more.") == nil)
    #expect(CleanupStream().rest(of: "  Nothing taken.  ") == "Nothing taken.")
  }
}
