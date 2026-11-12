import Foundation
import Testing
@testable import V2T

/// An AudioSource that records nothing (named apart from #127's SpyAudio, so both test files build together).
final class SilentAudio: AudioSource, @unchecked Sendable {
  private(set) var running = false
  private(set) var calls: [String] = []
  func warmUp() throws { running = true; calls.append("warmUp") }
  func coolDown() { running = false; calls.append("coolDown") }
  func begin() {}
  /// A stray tap's worth of audio, so finishing it needs no model.
  func end() -> [Float] { [Float](repeating: 0, count: 100) }
  func captured(from offset: Int) -> [Float] { [] }
  var level: Float { 0 }
  var microphone: Microphone? { nil }
}

/// Deleting the speech model never pulls it from under a dictation that is still being transcribed.
@MainActor struct ModelDeleteTests {
  let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-delete-\(UUID().uuidString)")

  /// A service whose model is "on the device" and has loaded there before: a temporary folder with one file it
  /// requires.
  func service() throws -> DictationService {
    let model = dir.appending(path: "Models/model")
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1_000).write(to: model.appending(path: "vocab.json"))
    let store = ModelStore(modelFolder: model, folders: [dir.appending(path: "Models")]) { ModelStore.hasAll(["vocab.json"], in: $0) }
    store.markLoaded()
    return DictationService(recommendation: .current, history: History(file: dir.appending(path: "h.json")),
                            dictionary: PersonalDictionary(file: dir.appending(path: "d.txt")), recorder: SilentAudio(), store: store)
  }

  /// Stop, then the mic session stopped while that dictation is still being transcribed: Delete waits for it.
  @Test func deleteWaitsForATranscriptionLeftRunningAfterTheSessionStops() async throws {
    let dictation = try service()
    dictation.refreshModelStorage()
    dictation.warmUp()
    dictation.start()

    dictation.stop()
    dictation.coolDown()

    #expect(dictation.state == .needsApp)
    #expect(dictation.canDeleteModel == false)
    let deadline = Date().addingTimeInterval(10)
    while dictation.pendingTranscriptions > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(dictation.pendingTranscriptions == 0)
    #expect(dictation.canDeleteModel)
  }

  @Test func deleteRemovesTheModelAndMarksItMissing() async throws {
    let dictation = try service()
    dictation.refreshModelStorage()
    #expect(dictation.modelOnDevice)

    await dictation.deleteModel()

    #expect(dictation.modelOnDevice == false)
    #expect(dictation.modelBytes == 0)
    #expect(Settings.shared.defaults.bool(forKey: DictationChannel.modelMissingKey))
  }

  /// A model whose files are there but failed to load (damaged weights) cannot dictate either: the keyboard's
  /// mic then opens v2t on Try again rather than recording audio that cannot be transcribed.
  @Test func dictationNeedsAModelThatIsThereAndDidNotFailToLoad() {
    let cases: [(Bool, SpeechEngine.State)] = [
      (true, .ready), (true, .loading), (true, .notDownloaded), (true, .failed("damaged")), (false, .ready), (false, .notDownloaded),
    ]

    #expect(cases.map { DictationService.canDictate(modelOnDevice: $0.0, engine: $0.1, loadedBefore: true) } == [true, true, true, false, false, false])
  }

  /// Until the model has loaded once on this device (its first load compiles it), only a ready model records.
  @Test func aModelNeverLoadedHereRecordsOnlyOnceReady() {
    let states: [SpeechEngine.State] = [.ready, .loading, .notDownloaded, .downloading(0.5), .failed("damaged")]

    #expect(states.map { DictationService.canDictate(modelOnDevice: true, engine: $0, loadedBefore: false) } == [true, false, false, false, false])
  }
}
