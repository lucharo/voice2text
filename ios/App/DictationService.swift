import AVFoundation
import Foundation
import SwiftUI

/// The app's side of dictation: a warm microphone session the keyboard drives over the App Group, on-device
/// transcription, the dictionary and cleanup, and the result sent back to the keyboard.
@MainActor final class DictationService: ObservableObject {
  @Published private(set) var state: DictationState = .needsApp
  @Published private(set) var engineState: SpeechEngine.State = .notDownloaded
  @Published private(set) var downloadProgress: Double = 0
  @Published private(set) var lastText = ""
  @Published private(set) var warmUntil: Date?
  /// Set when the keyboard opened the app to start dictating: the screen asks the user to swipe back.
  @Published var cameFromKeyboard = false

  let recommendation: Recommendation
  let history: History
  let dictionary: PersonalDictionary
  private let engine: SpeechEngine
  private let recorder: AudioSource = {
    if let path = ProcessInfo.processInfo.environment["V2T_FIXTURE_AUDIO"], let f = FixtureAudio(path: path) { return f }
    return Recorder()
  }()
  private let cleaner: Cleaner
  private let defaults = Settings.shared.defaults
  private var observers: [DarwinObserver] = []
  private var heartbeat: Timer?

  init(recommendation: Recommendation, history: History, dictionary: PersonalDictionary) {
    self.recommendation = recommendation
    self.history = history
    self.dictionary = dictionary
    self.engine = SpeechEngine(speech: recommendation.speech)
    self.cleaner = Cleaner(kind: recommendation.cleanup)
    observers = [
      DictationChannel.observe(DictationChannel.start) { [weak self] in self?.start() },
      DictationChannel.observe(DictationChannel.stop) { [weak self] in self?.stop() },
    ]
  }

  // MARK: model

  func prepareModel() async {
    guard engineState != .ready, engineState != .loading else { return }
    if case .downloading = engineState { return }
    engineState = .downloading(0)
    do {
      try await engine.prepare(language: Settings.shared.speechLanguage) { p in
        Task { @MainActor in
          self.downloadProgress = p
          self.engineState = p >= 1 ? .loading : .downloading(p)
        }
      }
      engineState = .ready
    } catch {
      engineState = .failed(error.localizedDescription)
    }
  }

  // MARK: session

  /// Opens the microphone session and keeps it warm (call while the app is in front).
  func warmUp() {
    do {
      try recorder.warmUp()
      extendWarmth()
      publish(.idle)
      heartbeat?.invalidate()
      heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.beat() }
      }
      beat()
    } catch {
      publish(.needsApp)
    }
  }

  func coolDown() {
    recorder.coolDown()
    heartbeat?.invalidate()
    heartbeat = nil
    warmUntil = nil
    defaults.set(0, forKey: DictationChannel.heartbeatKey)
    publish(.needsApp)
  }

  private func extendWarmth() {
    let minutes = Settings.shared.warmMinutes
    warmUntil = minutes == 0 ? nil : Date().addingTimeInterval(TimeInterval(minutes * 60))
  }

  private func beat() {
    if let until = warmUntil, Date() > until, state == .idle { coolDown(); return }
    defaults.set(Date().timeIntervalSince1970, forKey: DictationChannel.heartbeatKey)
  }

  /// The keyboard opened the app (v2t://dictate): start the session and begin recording at once, so the
  /// user can swipe back and keep talking.
  func handleKeyboardLaunch() {
    cameFromKeyboard = true
    if !recorder.running { warmUp() }
    start()
  }

  func start() {
    guard state == .idle || state == .needsApp else { return }
    if !recorder.running { warmUp() }
    guard recorder.running else { return }
    recorder.begin()
    publish(.listening)
  }

  func stop() {
    guard state == .listening else { return }
    let samples = recorder.end()
    publish(.transcribing)
    extendWarmth()
    Task { await finish(samples) }
  }

  private func finish(_ samples: [Float]) async {
    defer { publish(recorder.running ? .idle : .needsApp) }
    guard samples.count > 16_000 / 4 else { return }  // under a quarter second: a stray tap
    if engineState != .ready { await prepareModel() }
    let language = Settings.shared.speechLanguage
    do {
      let raw = try await engine.transcribe(samples, language: language)
      var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      if Settings.shared.cleanupEnabled { text = await cleaner.clean(text, terms: dictionary.terms) }
      text = dictionary.applyReplacements(text)
      lastText = text
      try? history.add(Dictation(text: text, date: Date(), language: language))
      defaults.set(text, forKey: DictationChannel.resultKey)
      defaults.set(UUID().uuidString, forKey: DictationChannel.resultIdKey)
      DictationChannel.post(DictationChannel.changed)
    } catch {
      lastText = "Couldn't transcribe: \(error.localizedDescription)"
    }
  }

  private func publish(_ s: DictationState) {
    state = s
    defaults.set(s.rawValue, forKey: DictationChannel.stateKey)
    DictationChannel.post(DictationChannel.changed)
  }
}
