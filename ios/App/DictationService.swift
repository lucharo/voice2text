import AVFoundation
import Foundation
import SwiftUI
import V2TSpeech

/// The app's side of dictation: a warm microphone session the keyboard drives over the App Group, on-device
/// transcription, the dictionary and cleanup, and the result sent back to the keyboard.
@MainActor final class DictationService: ObservableObject {
  @Published private(set) var state: DictationState = .needsApp
  @Published private(set) var engineState: SpeechEngine.State = .notDownloaded {
    didSet { publishCanDictate() }  // a first load starting or ending changes what the keyboard's mic does
  }
  @Published private(set) var lastText = ""
  @Published private(set) var warmUntil: Date?
  /// The input the warm session records from, also sent to the keyboard; nil when the session is off.
  @Published private(set) var microphone: Microphone?

  /// The speech model's files are on the device (downloaded only when the user asks, #124).
  @Published private(set) var modelOnDevice = false
  /// Bytes the model takes on the device, its compiled copy included.
  @Published private(set) var modelBytes: Int64 = 0
  /// The model has loaded on this device since it was downloaded, so loading it again reuses the copy Core ML
  /// compiled for this device the first time instead of compiling it.
  @Published private(set) var modelLoadedBefore = false
  /// Why deleting the model or the history failed, shown under the button.
  @Published private(set) var storageError: String?
  /// Deleting the model: no recording, preparation or second delete starts until it is done.
  @Published private(set) var deletingModel = false
  /// Dictations stopped but not yet transcribed. A cancelled one counts until its piece already in the model
  /// returns, so the model is never deleted under a decode still running.
  @Published private(set) var pendingTranscriptions = 0
  /// Set when the keyboard opened the app to start dictating: the screen asks the user to swipe back.
  @Published var cameFromKeyboard = false

  /// Re-read whenever the app comes forward, so turning Apple Intelligence on or off in Settings shows here.
  @Published private(set) var recommendation: Recommendation
  let history: History
  let dictionary: PersonalDictionary
  private let engine: any SpeechModel
  private let store: ModelStore
  private let recorder: AudioSource
  /// The time now; unit tests move it on to reach the session's expiry.
  private let now: () -> Date
  private static func defaultRecorder() -> AudioSource {
    guard let path = ProcessInfo.processInfo.environment["V2T_FIXTURE_AUDIO"] else { return Recorder() }
    // a test asked for the synthetic clip: never fall back to the real microphone
    guard let f = FixtureAudio(path: path) else { preconditionFailure("V2T_FIXTURE_AUDIO is set but unreadable: \(path)") }
    return f
  }
  private let defaults: UserDefaults
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
  /// Cleans the current recording's settled sentences while it is recorded, when cleanup is on.
  private var liveCleanup: LiveCleanup?
  /// The stopped dictation being transcribed now, so Cancel or the end of the session can stop it.
  private var finishing: (id: Int, task: Task<Void, Never>, live: LiveTranscription?, cleanup: LiveCleanup?)?

  /// `recorder`, `store`, `engine`, `defaults` and `now` are for unit tests; the app records from the
  /// microphone (or the UI tests' fixture clip) and transcribes with FluidAudio.
  init(recommendation: Recommendation, history: History, dictionary: PersonalDictionary, recorder: AudioSource? = nil, store: ModelStore? = nil,
       engine: (any SpeechModel)? = nil, defaults: UserDefaults = Settings.shared.defaults, now: @escaping () -> Date = Date.init) {
    self.recorder = recorder ?? Self.defaultRecorder()
    self.recommendation = recommendation
    self.history = history
    self.dictionary = dictionary
    let models = store == nil ? Self.modelsDirectory(for: recommendation.speech) : nil
    self.engine = engine ?? SpeechEngine(speech: recommendation.speech, modelsDirectory: models)
    self.store = store ?? .forDevice(recommendation.speech, modelsDirectory: models)
    self.defaults = defaults
    self.now = now
    observers = [
      DictationChannel.observe(DictationChannel.start) { [weak self] in self?.start() },
      DictationChannel.observe(DictationChannel.stop) { [weak self] in self?.stop() },
      DictationChannel.observe(DictationChannel.cancel) { [weak self] in self?.cancelTranscription() },
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
    if r != recommendation { recommendation = r; publishCanDictate() }
  }

  // MARK: model

  /// The speech model's folder: FluidAudio/Models in the App Group's container, where another app of the group
  /// can load the same download. A download an earlier version made in v2t's own Application Support moves there
  /// first, and stays in use where it is while that move fails. Nil (v2t's own folder) without the App Group.
  static func modelsDirectory(for speech: SpeechEngine.Model) -> URL? {
    SpeechEngine.modelsDirectory(appGroup: Settings.group).map { SpeechEngine.moveDownload(of: speech, into: $0) }
  }

  /// Re-reads whether the model is on the device and its size, and tells the keyboard: without the model, its
  /// mic key opens v2t, which offers the download, instead of recording something it cannot transcribe.
  func refreshModelStorage() {
    modelOnDevice = store.isOnDevice
    modelBytes = store.bytes
    modelLoadedBefore = store.hasLoaded
    publishCanDictate()
  }

  private func publishCanDictate() {
    defaults.set(!canDictate, forKey: DictationChannel.modelMissingKey)
  }

  /// Dictation can record: the device's tier supports it, the model is on the device, did not fail to load
  /// (damaged files fail offline; only the user's Try again may repair them), and is not being loaded for the
  /// first time. Otherwise the keyboard's mic opens v2t on that screen.
  var canDictate: Bool {
    Self.canDictate(supported: recommendation.tier != .notSupported, modelOnDevice: modelOnDevice, engine: engineState, loadedBefore: modelLoadedBefore)
  }

  static func canDictate(supported: Bool, modelOnDevice: Bool, engine: SpeechEngine.State, loadedBefore: Bool) -> Bool {
    guard supported, modelOnDevice else { return false }
    switch engine {
    case .ready: return true
    case .failed: return false
    // not loaded yet: a model that loaded here before reuses its compiled copy, so a recording may start and
    // wait for the load (the keyboard's first mic tap launches v2t, which loads the model as it opens). The
    // first load compiles the model for this device's Neural Engine, which nobody has timed on older chips:
    // a recording made then could not be transcribed until it ends, so nothing records until it is done.
    default: return loadedBefore
    }
  }

  /// At launch: loads the model if it is on the device, offline; never starts a download (#124).
  func loadModelIfOnDevice() async {
    refreshModelStorage()
    guard modelOnDevice else { return }
    await prepareModel(allowDownload: false)
  }

  /// Any speech-model files left (a partial download, or what a failed delete left behind) can be deleted.
  var canDeleteModel: Bool {
    modelBytes > 0 && !deletingModel && pendingTranscriptions == 0 && !engineState.isPreparing && state != .listening && state != .transcribing
  }

  /// Deletes the model's files and its compiled copy; dictation then needs a new download.
  func deleteModel() async {
    guard canDeleteModel else { return }
    deletingModel = true
    defer { deletingModel = false }
    storageError = nil
    // mark it gone before the first await, so a keyboard start arriving meanwhile is refused
    modelOnDevice = false
    defaults.set(true, forKey: DictationChannel.modelMissingKey)
    await engine.unload()
    engineState = .notDownloaded
    do { try store.delete() } catch { storageError = "Couldn't delete the model: \(error.localizedDescription)" }
    refreshModelStorage()
  }

  func clearHistory() {
    storageError = nil
    do { try history.clear() } catch { storageError = "Couldn't clear History: \(error.localizedDescription)" }
  }

  /// Loads the model; `allowDownload` only from the user's Download or Try again.
  func prepareModel(allowDownload: Bool = true) async {
    // a device not supported yet never downloads or compiles the model (it would only heat the phone)
    guard engineState != .ready, !deletingModel, recommendation.tier != .notSupported else { return }
    if let preparing { await preparing.value; return }
    let task = Task { await self.loadModel(allowDownload: allowDownload) }
    preparing = task
    await task.value
    preparing = nil
  }

  private func loadModel(allowDownload: Bool) async {
    prepareAttempt += 1
    let attempt = prepareAttempt
    engineState = .loading  // a cached model only loads; the first download's progress replaces this
    do {
      try await engine.prepare(language: Settings.shared.speechLanguage, allowDownload: allowDownload) { s in
        Task { @MainActor in
          // a report that lands after ready or failed, or from an earlier attempt, never undoes it
          guard self.prepareAttempt == attempt, self.engineState.isPreparing else { return }
          self.engineState = s
        }
      }
      store.markLoaded()
      modelLoadedBefore = true
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
    cancelTranscription()  // a dictation still transcribing ends with the session: nothing keeps decoding
    stopMeter()
    live?.abandon()
    live = nil
    liveCleanup?.abandon()
    liveCleanup = nil
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
    warmUntil = minutes == 0 ? nil : now().addingTimeInterval(TimeInterval(minutes * 60))
  }

  /// Every second while the session is warm (internal for tests). Stop sets the session's time from Done, so a
  /// dictation still transcribing past it has run the whole of the user's warm time: it ends with the session
  /// rather than keeping the microphone on for ever.
  func beat() {
    if let until = warmUntil, now() > until, [.idle, .transcribing, .cleaningUp].contains(state) { coolDown(); return }
    defaults.set(Date().timeIntervalSince1970, forKey: DictationChannel.heartbeatKey)
  }

  /// The keyboard opened the app (v2t://dictate): start the session and begin recording at once, so the
  /// user can swipe back and keep talking.
  func handleKeyboardLaunch() {
    cameFromKeyboard = true
    guard canDictate else { return }  // the hand-off screen offers the download or Try again, or says it is unsupported
    if !recorder.running { warmUp() }
    start()
  }

  func start() {
    guard state == .idle || state == .needsApp else { return }
    guard canDictate, !deletingModel else { return }  // nothing to transcribe with: the keyboard opens the app instead
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
    liveCleanup = nil
    if Settings.shared.cleanupEnabled, recommendation.cleanup == .appleIntelligence {
      dictionary.reload()  // the keyboard may have added words since
      let cleaner = Cleaner(kind: recommendation.cleanup)
      let cleanup = LiveCleanup(terms: dictionary.terms) { await cleaner.cleanReporting($0, terms: $1) }
      liveCleanup = cleanup
      live?.onPieces = { cleanup.offer(pieces: $0) }
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
    liveCleanup?.stop()  // a segment still queued is cleaned with the tail, not sent while the tail is decoded
    let samples = recorder.end()
    publish(.transcribing)
    extendWarmth()
    let id = recording, request = requestId, live = live, language = language, liveCleanup = liveCleanup
    self.live = nil
    self.liveCleanup = nil
    pendingTranscriptions += 1
    let task = Task {
      await finish(samples, id: id, request: request, language: language, live: live, liveCleanup: liveCleanup, stoppedAt: stoppedAt)
      pendingTranscriptions -= 1
      if finishing?.id == id { finishing = nil }
    }
    finishing = (id, task, live, liveCleanup)
  }

  /// The keyboard's Cancel after Done, or the session ending: the dictation being transcribed stops after the
  /// piece already in the model, and nothing it produces is typed or kept in History. The keyboard is free at once.
  func cancelTranscription() {
    guard let f = finishing else { return }
    finishing = nil
    f.task.cancel()
    f.live?.abandon()
    f.cleanup?.abandon()
    dictationLog.log("transcription cancelled")
    if f.id == recording, state == .transcribing || state == .cleaningUp { publish(recorder.running ? .idle : .needsApp) }
  }

  private func finish(
    _ samples: [Float], id: Int, request: String, language: String, live: LiveTranscription?, liveCleanup: LiveCleanup?,
    stoppedAt: ContinuousClock.Instant
  ) async {
    defer { liveCleanup?.abandon() }  // an early return (a stray tap, no text) leaves nothing cleaning
    // only the latest recording owns the state: a reset session may already be listening again
    defer { if id == recording, state == .transcribing || state == .cleaningUp { publish(recorder.running ? .idle : .needsApp) } }
    guard samples.count > 16_000 / 4 else { return }  // under a quarter second: a stray tap
    if let preparing {
      // a download or repair the user started (Download, Try again) is under way: wait for it, so the
      // recording, held in memory only, is transcribed once it finishes instead of being dropped
      await preparing.value
    } else if engineState != .ready {
      // load a model that is on the device, but never download one behind the user's back
      guard store.isOnDevice else { lastText = "Couldn't transcribe: the speech model is not on this \(recommendation.deviceName)."; return }
      await prepareModel(allowDownload: false)
    }
    guard !Task.isCancelled else { return }  // cancelled while the model loaded: nothing to decode
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
      guard !text.isEmpty, !Task.isCancelled else { return }
      let heard = text
      dictionary.reload()  // the keyboard may have added words since
      var cleanup: Duration?
      var cleanedWhileRecording: Int?
      if Settings.shared.cleanupEnabled, recommendation.cleanup == .appleIntelligence {
        // only from .transcribing: a session cooled down meanwhile (.needsApp) or a newer recording keeps its state
        if id == recording, state == .transcribing { publish(.cleaningUp) }
        let t0 = ContinuousClock.now
        if let liveCleanup {
          // the settled sentences were cleaned while recording: only the rest is cleaned now
          let result = await liveCleanup.finish(text, terms: dictionary.terms)
          text = result.text
          cleanedWhileRecording = result.cleanedWhileRecording
        } else {
          text = await Cleaner(kind: recommendation.cleanup).clean(text, terms: dictionary.terms)
        }
        cleanup = ContinuousClock.now - t0
      }
      text = dictionary.applyReplacements(text)
      guard !Task.isCancelled else { return }  // cancelled during cleanup: neither typed nor kept
      lastText = text
      // the text goes to the keyboard first; History is written after, so its time is not in the wait
      if id == recording {  // otherwise kept in History, but not typed into whatever field is open now
        defaults.set(text, forKey: DictationChannel.resultKey)
        defaults.set(request, forKey: DictationChannel.resultIdKey)
        DictationChannel.post(DictationChannel.changed)
      }
      let timings = DictationTimings(
        audio: Double(samples.count) / 16_000, speech: speech.seconds, cleanup: cleanup?.seconds,
        total: (ContinuousClock.now - stoppedAt).seconds, piecesWhileRecording: pieces, cleanedWhileRecording: cleanedWhileRecording)
      try? history.add(Dictation(text: text, heard: text == heard ? nil : heard, date: Date(), language: language, timings: timings))
      dictationLog.log("text ready \(timings.summary, privacy: .public)")
    } catch {
      guard !Task.isCancelled else { return }  // the user ended it: not an error to show
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
