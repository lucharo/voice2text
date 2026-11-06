import Foundation
import Testing
@testable import V2T

/// An AudioSource that records nothing and counts how the session is started and stopped.
final class SpyAudio: AudioSource, @unchecked Sendable {
  private(set) var running = false
  private(set) var calls: [String] = []
  var failWarmUp = false
  struct Refused: Error {}
  func warmUp() throws {
    calls.append("warmUp")
    if failWarmUp { throw Refused() }
    running = true
  }
  func coolDown() { running = false; calls.append("coolDown") }
  func begin() {}
  func end() -> [Float] { [] }
  func captured(from offset: Int) -> [Float] { [] }
  var level: Float { 0 }
  var microphone: Microphone? { running ? Microphone(name: "Spy") : nil }
}

/// Changing Dictation › Microphone: a warm, idle session restarts so the new choice takes effect at once.
@MainActor struct MicrophoneChoiceTests {
  let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-choice-\(UUID().uuidString)")

  func service(_ spy: SpyAudio) -> DictationService {
    DictationService(recommendation: .current, history: History(file: dir.appending(path: "h.json")),
                     dictionary: PersonalDictionary(file: dir.appending(path: "d.txt")), recorder: spy)
  }

  @Test func anIdleWarmSessionRestartsWithTheNewChoice() {
    let spy = SpyAudio()
    let dictation = service(spy)
    dictation.warmUp()

    dictation.applyMicrophoneChoice()

    #expect(spy.calls == ["warmUp", "coolDown", "warmUp"])
    #expect(spy.running)
    dictation.coolDown()
  }

  /// The new microphone cannot start: the session ends cleanly rather than leaving its heartbeat running.
  @Test func aFailedRestartEndsTheSession() {
    let spy = SpyAudio()
    let dictation = service(spy)
    dictation.warmUp()
    spy.failWarmUp = true

    dictation.applyMicrophoneChoice()

    #expect(dictation.state == .needsApp)
    #expect(dictation.warmUntil == nil)
    #expect(spy.running == false)
  }

  @Test func noSessionMeansNothingRestarts() {
    let spy = SpyAudio()
    let dictation = service(spy)

    dictation.applyMicrophoneChoice()

    #expect(spy.calls == [])
  }

  @Test func theChoicePersists() {
    let defaults = UserDefaults(suiteName: "v2t-choice-\(UUID().uuidString)")!

    Settings(defaults: defaults).microphoneChoice = .connected

    #expect(Settings(defaults: defaults).microphoneChoice == .connected)
  }
}
