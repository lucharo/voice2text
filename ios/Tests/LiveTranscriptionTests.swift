import Foundation
import Testing
@testable import V2T

/// A microphone that has "recorded" whatever the test puts in `samples`.
private final class FakeSource: AudioSource, @unchecked Sendable {
  var samples: [Float] = []
  var running: Bool { true }
  func warmUp() throws {}
  func coolDown() {}
  func begin() {}
  func end() -> [Float] { samples }
  var level: Float { 0 }
  var microphone: Microphone? { nil }
  func captured(from offset: Int) -> [Float] { offset < samples.count ? Array(samples[offset...]) : [] }
}

private actor Calls {
  var lengths: [Int] = []
  func decode(_ samples: [Float]) -> String {
    lengths.append(samples.count)
    return "<\(samples.count)>"
  }
}

/// 13 s of speech, a 0.5 s pause, then 11 s more: one cut at 13.05 s, mid-pause.
private let dictation: [Float] =
  (0..<(13 * 16_000)).map { $0 % 2 == 0 ? 0.5 : -0.5 } + [Float](repeating: 0, count: 8_000)
  + (0..<(11 * 16_000)).map { $0 % 2 == 0 ? 0.5 : -0.5 }

@MainActor struct LiveTranscriptionTests {
  /// Waits up to 2 s for the model to have been called `count` times.
  private func waitForCalls(_ calls: Calls, count: Int) async throws {
    for _ in 0..<200 where await calls.lengths.count < count { try await Task.sleep(nanoseconds: 10_000_000) }
  }

  @Test func theRecordingSoFarIsDecodedInPiecesBeforeStop() async throws {
    let source = FakeSource(), calls = Calls()
    let live = LiveTranscription(source: source, isReady: { true }) { await calls.decode($0) }
    source.samples = dictation

    live.feed()
    try await waitForCalls(calls, count: 1)
    let beforeStop = await calls.lengths
    let text = try await live.finish(dictation, stoppedAt: .now).text

    #expect(beforeStop == [208_800])
    #expect(await calls.lengths == [208_800, 183_200])
    #expect(text == "<208800> <183200>")
  }

  @Test func nothingIsDecodedWhileTheModelIsStillLoading() async throws {
    let source = FakeSource(), calls = Calls()
    let live = LiveTranscription(source: source, isReady: { false }) { await calls.decode($0) }
    source.samples = dictation

    live.feed()
    try await Task.sleep(nanoseconds: 100_000_000)
    let beforeStop = await calls.lengths
    let text = try await live.finish(dictation, stoppedAt: .now).text

    #expect(beforeStop == [])
    #expect(await calls.lengths == [208_800, 183_200])
    #expect(text == "<208800> <183200>")
  }

  @Test func eachLookHandsOverOnlyTheNewAudio() async throws {
    let source = FakeSource(), calls = Calls()
    let live = LiveTranscription(source: source, isReady: { true }) { await calls.decode($0) }

    source.samples = Array(dictation[..<(10 * 16_000)])
    live.feed()
    try await Task.sleep(nanoseconds: 50_000_000)
    source.samples = dictation
    live.feed()
    try await waitForCalls(calls, count: 1)

    // had the first 10 s been handed over twice, the cut would fall in the repeat, not at 13.05 s
    #expect(await calls.lengths == [208_800])
  }
}
