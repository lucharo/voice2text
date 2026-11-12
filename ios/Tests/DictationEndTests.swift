import Foundation
import Testing
@testable import V2T

/// A speech model that loads at once and names each decode by its length; the next load or decode can be held
/// until `release()`, standing in for a slow compile or a decode that never ends.
actor StubSpeech: SpeechModel {
  private(set) var decodes: [Int] = []
  private var holdLoad = false
  private var holdDecode = false
  private var gate: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?

  func prepare(language: String, allowDownload: Bool, progress: @escaping @Sendable (SpeechEngine.State) -> Void) async throws {
    if holdLoad { holdLoad = false; await hold() }
  }

  func unload() {}

  func transcribe(_ samples: [Float], language: String) async throws -> String {
    decodes.append(samples.count)
    if holdDecode { holdDecode = false; await hold() }
    return "<\(samples.count)>"
  }

  func holdTheNextLoad() { holdLoad = true }
  func holdTheNextDecode() { holdDecode = true }
  /// Returns once the held load or decode has started.
  func waitUntilHeld() async {
    if gate != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func release() { gate?.resume(); gate = nil }

  private func hold() async {
    await withCheckedContinuation {
      gate = $0
      started?.resume()
      started = nil
    }
  }
}

/// A microphone whose whole recording arrives at Stop (nothing while recording), so every piece is decoded then.
final class StoppedAudio: AudioSource, @unchecked Sendable {
  /// 13 s of speech, a pause, 11.5 s, a pause, 14 s: three pieces at Stop, the first 208,800 samples.
  let samples: [Float] = {
    func speech(_ s: Double) -> [Float] { (0..<Int(s * 16_000)).map { $0 % 2 == 0 ? 0.5 : -0.5 } }
    let pause = [Float](repeating: 0, count: 8_000)
    return speech(13) + pause + speech(11.5) + pause + speech(14)
  }()
  private(set) var running = false
  func warmUp() throws { running = true }
  func coolDown() { running = false }
  func begin() {}
  func end() -> [Float] { samples }
  func captured(from offset: Int) -> [Float] { [] }
  var level: Float { 0 }
  var microphone: Microphone? { nil }
}

/// The clock the service reads, moved on by the test.
final class TestClock: @unchecked Sendable {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// A dictation can always be ended: Cancel after Done, turning the session off, or the session's own expiry
/// stops the transcription, and nothing it produces afterwards is typed or kept.
@MainActor struct DictationEndTests {
  let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-end-\(UUID().uuidString)")
  let defaults = UserDefaults(suiteName: "v2t-end-\(UUID().uuidString)")!
  let clock = TestClock()

  /// A service with its model "on the device" (a temporary folder), no cleanup, and `speech` as the model.
  func service(_ speech: StubSpeech, loadedBefore: Bool = false) throws -> DictationService {
    let model = dir.appending(path: "Models/model")
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1_000).write(to: model.appending(path: "vocab.json"))
    let store = ModelStore(modelFolder: model, folders: [dir.appending(path: "Models")]) { ModelStore.hasAll(["vocab.json"], in: $0) }
    if loadedBefore { store.markLoaded() }
    let noCleanup = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: false))
    let dictation = DictationService(
      recommendation: noCleanup, history: History(file: dir.appending(path: "h.json")),
      dictionary: PersonalDictionary(file: dir.appending(path: "d.txt")), recorder: StoppedAudio(), store: store,
      engine: speech, defaults: defaults, now: { [clock] in clock.now })
    dictation.refreshModelStorage()
    return dictation
  }

  /// Ready, warm, and stopped with the first piece held in the model.
  func transcribingWithTheFirstPieceHeld(_ speech: StubSpeech) async throws -> DictationService {
    let dictation = try service(speech)
    await dictation.prepareModel()
    dictation.warmUp()
    dictation.start()
    await speech.holdTheNextDecode()
    dictation.stop()
    await speech.waitUntilHeld()
    return dictation
  }

  /// Lets the cancelled piece finish in the model, then waits for the stopped dictation's work to end.
  func releaseAndWaitForTheWork(_ dictation: DictationService, _ speech: StubSpeech) async throws {
    try await Task.sleep(for: .milliseconds(50))  // the abandon reaches the transcriber's actor
    await speech.release()
    let deadline = Date().addingTimeInterval(10)
    while dictation.pendingTranscriptions > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
  }

  func expectNothingDelivered(_ dictation: DictationService) {
    #expect(defaults.string(forKey: DictationChannel.resultKey) == nil)
    #expect(dictation.history.items.isEmpty)
    #expect(dictation.lastText == "")
  }

  @Test func cancelAfterDoneFreesTheKeyboardStopsDecodingAndDeliversNothing() async throws {
    let speech = StubSpeech()
    let dictation = try await transcribingWithTheFirstPieceHeld(speech)

    dictation.cancelTranscription()
    let stateAtCancel = dictation.state
    try await releaseAndWaitForTheWork(dictation, speech)

    #expect(stateAtCancel == .idle)
    #expect(await speech.decodes == [208_800])  // the two pieces after the held one are never decoded
    #expect(dictation.pendingTranscriptions == 0)
    expectNothingDelivered(dictation)
    dictation.coolDown()
  }

  @Test func turningTheSessionOffWhileTranscribingStopsDecodingAndDeliversNothing() async throws {
    let speech = StubSpeech()
    let dictation = try await transcribingWithTheFirstPieceHeld(speech)

    dictation.coolDown()
    try await releaseAndWaitForTheWork(dictation, speech)

    #expect(dictation.state == .needsApp)
    #expect(await speech.decodes == [208_800])
    expectNothingDelivered(dictation)
  }

  /// Cancel while the dictation waits for the model to load: once it loads, nothing is decoded.
  @Test func cancelWhileTheModelLoadsDecodesNothing() async throws {
    let speech = StubSpeech()
    let dictation = try service(speech, loadedBefore: true)
    dictation.warmUp()
    dictation.start()
    await speech.holdTheNextLoad()
    dictation.stop()
    await speech.waitUntilHeld()

    dictation.cancelTranscription()
    try await releaseAndWaitForTheWork(dictation, speech)

    #expect(dictation.state == .idle)
    #expect(await speech.decodes == [])
    expectNothingDelivered(dictation)
    dictation.coolDown()
  }

  /// Positive control for the stubs: left alone, the same dictation is transcribed and typed.
  @Test func anUncancelledDictationIsDelivered() async throws {
    let speech = StubSpeech()
    let dictation = try await transcribingWithTheFirstPieceHeld(speech)

    try await releaseAndWaitForTheWork(dictation, speech)

    #expect(await speech.decodes == [208_800, 192_000, 231_200])
    #expect(defaults.string(forKey: DictationChannel.resultKey) == "<208800> <192000> <231200>")
    #expect(dictation.history.items.count == 1)
    #expect(dictation.state == .idle)
    dictation.coolDown()
  }
}

/// While the speech model loads for the first time, the keyboard's mic opens v2t instead of recording.
@MainActor struct ModelLoadingTests {
  let base = DictationEndTests()

  @Test func aFirstLoadKeepsTheMicFromRecording() async throws {
    let speech = StubSpeech()
    let dictation = try base.service(speech)
    await speech.holdTheNextLoad()
    let loading = Task { await dictation.prepareModel() }
    await speech.waitUntilHeld()

    dictation.warmUp()
    dictation.start()

    #expect(dictation.engineState == .loading)
    #expect(dictation.canDictate == false)
    #expect(base.defaults.bool(forKey: DictationChannel.modelMissingKey))
    #expect(dictation.state == .idle)
    await speech.release()
    await loading.value
    dictation.coolDown()
  }

  @Test func onceLoadedTheMicRecords() async throws {
    let speech = StubSpeech()
    let dictation = try base.service(speech)

    await dictation.prepareModel()

    #expect(dictation.canDictate)
    #expect(base.defaults.bool(forKey: DictationChannel.modelMissingKey) == false)
    #expect(try base.service(StubSpeech()).modelLoadedBefore)  // the next launch knows
  }

  /// A model that loaded here before reloads its compiled copy: a recording may start and wait for it, as the
  /// keyboard's first mic tap does when it launches v2t.
  @Test func aModelThatLoadedBeforeMayRecordWhileItReloads() async throws {
    let speech = StubSpeech()
    let dictation = try base.service(speech, loadedBefore: true)
    await speech.holdTheNextLoad()
    let loading = Task { await dictation.prepareModel() }
    await speech.waitUntilHeld()

    dictation.warmUp()
    dictation.start()

    #expect(dictation.canDictate)
    #expect(base.defaults.bool(forKey: DictationChannel.modelMissingKey) == false)
    #expect(dictation.state == .listening)
    await speech.release()
    await loading.value
    dictation.coolDown()
  }
}
