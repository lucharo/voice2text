import AVFoundation
import Foundation
import SwiftUI

/// The app's side of dictation: a warm microphone session the keyboard drives over the App Group, on-device
/// transcription, the dictionary and cleanup, and the result sent back to the keyboard.
@MainActor final class DictationService: ObservableObject {
  @Published private(set) var state: DictationState = .needsApp
  @Published private(set) var engineState: SpeechEngine.State = .notDownloaded
  @Published private(set) var lastText = ""
  @Published private(set) var warmUntil: Date?
  /// The input the warm session records from, also sent to the keyboard; nil when the session is off.
  @Published private(set) var microphone: Microphone?

  /// The speech model's files are on the device (downloaded only when the user asks, #124).
  @Published private(set) var modelOnDevice = false
  /// Bytes the model takes on the device, its compiled copy included.
  @Published private(set) var modelBytes: Int64 = 0
  /// Why deleting the model or the history failed, shown under the button.
  @Published private(set) var storageError: String?
  /// Set when the keyboard opened the app to start dictating: the screen asks the user to swipe back.
  @Published var cameFromKeyboard = false

  /// Re-read whenever the app comes forward, so turning Apple Intelligence on or off in Settings shows here.
  @Published private(set) var recommendation: Recommendation
  let history: History
  let dictionary: PersonalDictionary
  private let engine: SpeechEngine
  private let store: ModelStore
  private let recorder: AudioSource
  private static func defaultRecorder() -> AudioSource {
    guard let path = ProcessInfo.processInfo.environment["V2T_FIXTURE_AUDIO"] else { return Recorder() }
    // a test asked for the synthetic clip: never fall back to the real microphone
    guard let f = FixtureAudio(path: path) else { preconditionFailure("V2T_FIXTURE_AUDIO is set but unreadable: \(path)") }
    return f
  }
  private let defaults = Settings.shared.defaults
  private var observers: [DarwinObserver] = []
  private var routeObserver: NSObjectProtocol?
  private var heartbeat: Timer?
  /// Samples the microphone level 20 times a second while listening, for the keyboard's waveform.
  private var meter: Timer?
  private var levels: [Float] = []
  /// Counts model preparations, so a late progress report from an earlier one is dropped.
  private var prepareAttempt = 0
  /// The preparation under way, so a dictation that ends meanwhile waits for it instead of failing.
  private var preparing: Task<Void, Never>?
  /// Counts recordings; a transcription finishing after the session was reset and a new recording begun
  /// must not change that recording's state or type into the keyboard.
  private var recording = 0
  /// The keyboard request that started the current recording; the result carries it back.
  private var requestId = ""
  /// Transcribes the current recording in pieces while it is being made (#112).
  private var live: LiveTranscription?
  /// The speech language when the current recording began: its pieces, its History entry (#112).
  private var language = ""

  /// `recorder` is for unit tests; the app records from the microphone (or the UI tests' fixture clip).
  init(recommendation: Recommendation, history: History, dictionary: PersonalDictionary, recorder: AudioSource? = nil) {
    self.recorder = recorder ?? Self.defaultRecorder()
    self.recommendation = recommendation
    self.history = history
    self.dictionary = dictionary
    self.engine = SpeechEngine(speech: recommendation.speech)
    self.store = .forDevice(modelFolder: SpeechEngine.modelFolder(for: recommendation.speech))
    observers = [
      DictationChannel.observe(DictationChannel.start) { [weak self] in self?.start() },
      DictationChannel.observe(DictationChannel.stop) { [weak self] in self?.stop() },
    ]
    // a headset plugged in or AirPods connected mid-session can change the input
    routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishMicrophone() }
    }
    refreshModelStorage()
  }

  private func publishMicrophone() {
    let mic = recorder.microphone
    guard mic != microphone else { return }
    microphone = mic
    DictationChannel.writeMicrophone(mic, to: defaults)
    DictationChannel.post(DictationChannel.changed)
  }

  func refreshRecommendation() {
    let r = Recommendation.current
    if r != recommendation { recommendation = r }
  }

  // MARK: model

  /// Re-reads whether the model is on the device and its size, and tells the keyboard: without the model, its
  /// mic key opens v2t, which offers the download, instead of recording something it cannot transcribe.
  func refreshModelStorage() {
    modelOnDevice = store.isOnDevice
    modelBytes = store.bytes
    defaults.set(!modelOnDevice, forKey: DictationChannel.modelMissingKey)
  }

  /// At launch: loads the model if it is on the device; never starts a download (#124).
  func loadModelIfOnDevice() async {
    refreshModelStorage()
    guard modelOnDevice else { return }
    await prepareModel()
  }

  var canDeleteModel: Bool {
    modelOnDevice && !engineState.isPreparing && state != .listening && state != .transcribing
  }

  /// Deletes the model's files and its compiled copy; dictation then needs a new download.
  func deleteModel() async {
    guard canDeleteModel else { return }
    storageError = nil
    await engine.unload()
    engineState = .notDownloaded
    do { try store.delete() } catch { storageError = "Couldn't delete the model: \(error.localizedDescription)" }
    refreshModelStorage()
  }

  func clearHistory() {
    storageError = nil
    do { try history.clear() } catch { storageError = "Couldn't clear History: \(error.localizedDescription)" }
  }

  func prepareModel() async {
    guard engineState != .ready else { return }
    if let preparing { await preparing.value; return }
    let task = Task { await self.loadModel() }
    preparing = task
    await task.value
    preparing = nil
  }

  private func loadModel() async {
    prepareAttempt += 1
    let attempt = prepareAttempt
    engineState = .loading  // a cached model only loads; the first download's progress replaces this
    do {
      try await engine.prepare(language: Settings.shared.speechLanguage) { s in
        Task { @MainActor in
          // a report that lands after ready or failed, or from an earlier attempt, never undoes it
          guard self.prepareAttempt == attempt, self.engineState.isPreparing else { return }
          self.engineState = s
        }
      }
      engineState = .ready
    } catch {
      engineState = .failed(error.localizedDescription)
    }
    refreshModelStorage()
  }

  // MARK: session

  /// Opens the microphone session and keeps it warm (call while the app is in front).
  func warmUp() {
    do {
      try recorder.warmUp()
      publishMicrophone()
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
    stopMeter()
    live?.abandon()
    live = nil
    recorder.coolDown()
    publishMicrophone()
    heartbeat?.invalidate()
    heartbeat = nil
    warmUntil = nil
    defaults.set(0, forKey: DictationChannel.heartbeatKey)
    publish(.needsApp)
  }

  /// Whether the picker may change the microphone now: only with no dictation under way (idle or no session),
  /// since a change applies by restarting the session, so never while listening, transcribing or cleaning up.
  static func allowsMicrophoneChange(_ state: DictationState) -> Bool { state == .idle || state == .needsApp }

  /// The microphone choice changed (in the app, so in the foreground): a warm, idle session restarts with it.
  /// The picker is disabled while listening or transcribing; with no session, the next warm-up uses it.
  func applyMicrophoneChoice() {
    guard recorder.running, state == .idle else { return }
    coolDown()  // the whole session (heartbeat, warm-until), so a failed restart leaves nothing running
    warmUp()
  }

  /// The "keep the mic ready" setting changed: a session already on runs for the new length from now.
  func applyWarmSetting() {
    if recorder.running { extendWarmth() }
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
    guard modelOnDevice else { return }  // the hand-off screen offers the download instead
    if !recorder.running { warmUp() }
    start()
  }

  func start() {
    guard state == .idle || state == .needsApp else { return }
    guard modelOnDevice else { return }  // nothing to transcribe with: the keyboard opens the app instead
    if !recorder.running { warmUp() }
    guard recorder.running else { return }
    recording += 1
    requestId = defaults.string(forKey: DictationChannel.requestIdKey) ?? ""
    recorder.begin()
    language = Settings.shared.speechLanguage
    let language = language
    live = LiveTranscription(source: recorder, isReady: { [weak self] in self?.engineState == .ready }) { [engine] in
      try await engine.transcribe($0, language: language)
    }
    live?.start()
    publish(.listening)
    levels = []
    meter?.invalidate()
    meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sampleLevel() }
    }
  }

  /// Appends the level, as 0...1 over a 45 dB range from near silence to loud speech.
  private func sampleLevel() {
    let db = 20 * log10(max(recorder.level, 1e-6))
    levels.append(min(1, max(0, (db + 55) / 45)))
    if levels.count > 96 { levels.removeFirst(levels.count - 96) }
    DictationChannel.writeLevels(levels)
  }

  private func stopMeter() {
    meter?.invalidate()
    meter = nil
    levels = []
    DictationChannel.writeLevels([])
  }

  func stop() {
    guard state == .listening else { return }
    stopMeter()
    let stoppedAt = ContinuousClock.now
    live?.stopFeeding()
    let samples = recorder.end()
    publish(.transcribing)
    extendWarmth()
    let id = recording, request = requestId, live = live, language = language
    self.live = nil
    Task { await finish(samples, id: id, request: request, language: language, live: live, stoppedAt: stoppedAt) }
  }

  private func finish(
    _ samples: [Float], id: Int, request: String, language: String, live: LiveTranscription?, stoppedAt: ContinuousClock.Instant
  ) async {
    // only the latest recording owns the state: a reset session may already be listening again
    defer { if id == recording, state == .transcribing || state == .cleaningUp { publish(recorder.running ? .idle : .needsApp) } }
    guard samples.count > 16_000 / 4 else { return }  // under a quarter second: a stray tap
    if engineState != .ready {
      // load a model that is on the device, but never download one behind the user's back
      guard store.isOnDevice else { lastText = "Couldn't transcribe: the speech model is not on this \(recommendation.deviceName)."; return }
      await prepareModel()
    }
    do {
      let raw: String
      var pieces = 0
      if let live {
        let result = try await live.finish(samples, stoppedAt: stoppedAt)
        raw = result.text
        pieces = result.report.piecesWhileRecording
      } else {
        raw = try await engine.transcribe(samples, language: language)
      }
      let speech = ContinuousClock.now - stoppedAt
      var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      let heard = text
      dictionary.reload()  // the keyboard may have added words since
      var cleanup: Duration?
      if Settings.shared.cleanupEnabled, recommendation.cleanup == .appleIntelligence {
        // only from .transcribing: a session cooled down meanwhile (.needsApp) or a newer recording keeps its state
        if id == recording, state == .transcribing { publish(.cleaningUp) }
        let t0 = ContinuousClock.now
        text = await Cleaner(kind: recommendation.cleanup).clean(text, terms: dictionary.terms)
        cleanup = ContinuousClock.now - t0
      }
      text = dictionary.applyReplacements(text)
      lastText = text
      // the text goes to the keyboard first; History is written after, so its time is not in the wait
      if id == recording {  // otherwise kept in History, but not typed into whatever field is open now
        defaults.set(text, forKey: DictationChannel.resultKey)
        defaults.set(request, forKey: DictationChannel.resultIdKey)
        DictationChannel.post(DictationChannel.changed)
      }
      let timings = DictationTimings(
        audio: Double(samples.count) / 16_000, speech: speech.seconds, cleanup: cleanup?.seconds,
        total: (ContinuousClock.now - stoppedAt).seconds, piecesWhileRecording: pieces)
      try? history.add(Dictation(text: text, heard: text == heard ? nil : heard, date: Date(), language: language, timings: timings))
      dictationLog.log("text ready \(timings.summary, privacy: .public)")
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

extension Duration {
  var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
