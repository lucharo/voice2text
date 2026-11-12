import Testing
@testable import V2TPieces

private let rate = 16_000

/// `seconds` of "speech": a square wave at ±0.5, loud enough that any silence is clearly quieter.
private func speech(_ seconds: Double) -> [Float] {
  (0..<Int(seconds * Double(rate))).map { $0 % 2 == 0 ? 0.5 : -0.5 }
}

private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

@Suite struct PieceCutterTests {
  let cutter = PieceCutter()

  @Test func noCutUntilTheWholeSearchRegionHasArrived() {
    let audio = speech(14.9)

    #expect(cutter.cut(audio.dropLast()) == nil)
    #expect(cutter.cut(audio[...]) != nil)
  }

  @Test func cutsInTheMiddleOfAPauseNearTheMark() {
    let audio = speech(13) + silence(0.5) + speech(5)

    // the first all-silent window starts at 13 s; the cut is its middle, 0.05 s in
    #expect(cutter.cut(audio[...]) == 13 * rate + 800)
  }

  @Test func aQuieterPauseOutsideTheSearchRegionIsIgnored() {
    let audio = speech(5) + silence(1) + speech(5.5) + [Float](repeating: 0.1, count: 8_000) + speech(6)

    // 5-6 s is silent but before 12 − 2.9 s; the quiet stretch at 11.5 s is the quietest inside
    #expect(cutter.cut(audio[...]) == 11 * rate + 8_000 + 800)
  }

  @Test func onATieTheEarliestQuietWindowWins() {
    let audio = silence(16)

    #expect(cutter.cut(audio[...]) == 145_600 + 800)  // 9.1 s, the region's start
  }

  @Test func theCutIsRelativeToTheSliceItIsGiven() {
    let audio = speech(3) + speech(13) + silence(0.5) + speech(5)

    #expect(cutter.cut(audio[(3 * rate)...]) == 13 * rate + 800)
  }

  @Test func everyPieceFitsOneEncoderWindowOfBothModels() {
    // FluidAudio 55f65d9: Nemotron Unified decodes up to 187 × 1,280 samples in one window, Parakeet v3 240,000
    #expect(cutter.longestPiece <= 187 * 1_280)
  }
}

/// A decoder that records what it was given and names each piece by its length in samples.
private actor FakeModel {
  var calls: [Int] = []
  var failOnCall: Int?
  var texts: [Int: String] = [:]
  private var gate: CheckedContinuation<Void, Never>?
  private var holdNext = false
  private var started: CheckedContinuation<Void, Never>?

  func decode(_ samples: [Float]) async throws -> String {
    calls.append(samples.count)
    if calls.count == failOnCall { throw Failure() }
    if holdNext {
      holdNext = false
      started?.resume()
      started = nil
      await withCheckedContinuation { gate = $0 }
    }
    return texts[calls.count] ?? "<\(samples.count)>"
  }

  func failing(on call: Int) { failOnCall = call }
  func text(_ text: String, forCall call: Int) { texts[call] = text }
  /// The next decode stops until `release()`; returns once it has started.
  func holdTheNextDecode() async {
    holdNext = true
  }
  func waitUntilHeld() async {
    if gate != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func release() { gate?.resume(); gate = nil }

  struct Failure: Error {}
}

private func transcriber(_ model: FakeModel) -> PieceTranscriber {
  PieceTranscriber { try await model.decode($0) }
}

/// Feeds `audio` half a second at a time, as the app's timer does.
private func record(_ audio: [Float], into t: PieceTranscriber) async {
  var at = 0
  while at < audio.count {
    let end = min(audio.count, at + rate / 2)
    await t.add(Array(audio[at..<end]))
    at = end
  }
}

@Suite struct PieceTranscriberTests {
  @Test func aShortDictationIsOneDecodeAtStop() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(10)

    await record(audio, into: t)
    let callsWhileRecording = await model.calls
    let (text, report) = try await t.finish(audio)

    #expect(callsWhileRecording == [])
    #expect(await model.calls == [160_000])
    #expect(text == "<160000>")
    #expect(report == PieceTranscriber.Report(piecesWhileRecording: 0, piecesAtFinish: 1, fellBack: false))
  }

  @Test func aLongDictationLeavesOnlyTheTailForStop() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11) + silence(0.5) + speech(10)  // 35 s, pauses at 13 s and 24.5 s

    await record(audio, into: t)
    let callsWhileRecording = await model.calls
    let (text, report) = try await t.finish(audio)

    // pieces end 0.05 s into each pause: 13.05 s, then 11.5 s more; the tail is the 10.45 s left
    #expect(callsWhileRecording == [208_800, 184_000])
    #expect(await model.calls == [208_800, 184_000, 167_200])
    #expect(text == "<208800> <184000> <167200>")
    #expect(report == PieceTranscriber.Report(piecesWhileRecording: 2, piecesAtFinish: 1, fellBack: false))
    #expect(await t.decodedSamples == 560_000)
  }

  @Test func audioThatArrivesOnlyAtStopIsStillCutIntoPieces() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11)

    let (text, report) = try await t.finish(audio)

    #expect(await model.calls == [208_800, 183_200])
    #expect(text == "<208800> <183200>")
    #expect(report == PieceTranscriber.Report(piecesWhileRecording: 0, piecesAtFinish: 2, fellBack: false))
  }

  @Test func aTailOfAFractionOfASecondIsPaddedToHalfASecond() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(14.5) + silence(0.4)  // the pause starts at 14.5 s: cut at 14.55 s, 0.35 s left

    await record(audio, into: t)
    let (text, report) = try await t.finish(audio)

    #expect(await model.calls == [232_800, 8_000])
    #expect(text == "<232800> <8000>")
    #expect(report == PieceTranscriber.Report(piecesWhileRecording: 1, piecesAtFinish: 1, fellBack: false))
    #expect(await t.decodedSamples == 238_400)  // the recording, not the padding
  }

  @Test func aShortRecordingWithNoCutIsNotPadded() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(0.3)

    let (text, _) = try await t.finish(audio)

    #expect(await model.calls == [4_800])
    #expect(text == "<4800>")
  }

  @Test func emptyPiecesAddNoSpaces() async throws {
    let model = FakeModel()
    await model.text(" ", forCall: 1)
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11)

    await record(audio, into: t)
    let (text, _) = try await t.finish(audio)

    #expect(text == "<183200>")
  }

  @Test func aFailedPieceFallsBackToTheWholeRecording() async throws {
    let model = FakeModel()
    await model.failing(on: 1)
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11)

    await record(audio, into: t)
    let (text, report) = try await t.finish(audio)

    #expect(await model.calls == [208_800, 392_000])
    #expect(text == "<392000>")
    #expect(report == PieceTranscriber.Report(piecesWhileRecording: 0, piecesAtFinish: 0, fellBack: true))
  }

  @Test func stopWaitsForAPieceAlreadyDecodingAndNeverDecodesItTwice() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11)
    await model.holdTheNextDecode()

    let adding = Task { await t.add(audio) }
    await model.waitUntilHeld()
    let finishing = Task { try await t.finish(audio) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let callsWhileHeld = await model.calls
    await model.release()
    _ = await adding.value
    let (text, report) = try await finishing.value

    #expect(callsWhileHeld == [208_800])
    #expect(await model.calls == [208_800, 183_200])
    #expect(text == "<208800> <183200>")
    #expect(report == PieceTranscriber.Report(piecesWhileRecording: 1, piecesAtFinish: 1, fellBack: false))
  }

  @Test func abandoningStopsThePiecesQueuedBehindTheOneDecoding() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11.5) + silence(0.5) + speech(14)  // three settled cuts at once
    await model.holdTheNextDecode()

    let adding = Task { await t.add(audio) }
    await model.waitUntilHeld()
    await t.abandon()
    await model.release()
    await adding.value

    #expect(await model.calls == [208_800])
  }

  /// Cancel after Done, while Stop is decoding the settled pieces: the piece already in the model ends, nothing
  /// after it is decoded, and Stop returns no text.
  @Test func abandoningDuringStopDecodesNoMorePiecesAndReturnsNoText() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11.5) + silence(0.5) + speech(14)  // three settled cuts at once
    await model.holdTheNextDecode()

    let finishing = Task { try await t.finish(audio) }
    await model.waitUntilHeld()
    await t.abandon()
    await model.release()
    let result = await finishing.result

    #expect(await model.calls == [208_800])
    #expect(throws: CancellationError.self) { try result.get() }
  }

  /// Cancel while the last piece is in the model: its text, when it comes, is not returned.
  @Test func abandoningWhileTheTailDecodesReturnsNoText() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(5)
    await model.holdTheNextDecode()

    let finishing = Task { try await t.finish(audio) }
    await model.waitUntilHeld()
    await t.abandon()
    await model.release()
    let result = await finishing.result

    #expect(await model.calls == [80_000])
    #expect(throws: CancellationError.self) { try result.get() }
  }

  /// Dropped before Stop reached it: Stop decodes nothing, not even the whole recording as a fallback.
  @Test func stopAfterAbandoningDecodesNothing() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(13) + silence(0.5) + speech(11)

    await t.abandon()
    let result = await Task { try await t.finish(audio) }.result

    #expect(await model.calls == [])
    #expect(throws: CancellationError.self) { try result.get() }
  }

  @Test func audioAddedAfterFinishIsIgnored() async throws {
    let model = FakeModel()
    let t = transcriber(model)
    let audio = speech(5)

    _ = try await t.finish(audio)
    await t.add(speech(20))

    #expect(await model.calls == [80_000])
  }
}
