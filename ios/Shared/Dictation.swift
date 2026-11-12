import Foundation

public enum DictationState: String, Sendable {
  /// The app's mic session is warm: the mic key records without leaving the host app.
  case idle
  /// No warm session: the mic key opens v2t once to start one.
  case needsApp
  case listening
  case transcribing
  /// Apple Intelligence is tidying the transcript (#123).
  case cleaningUp
  /// The keyboard has no Full Access, so it cannot talk to the app.
  case unavailable

  /// What the keyboard's recording panel says while the app works after Done (#123).
  public var waitingLabel: String { self == .cleaningUp ? "Cleaning up…" : "Transcribing…" }

  /// The same, with the time since Done ticking in tenths, to show how quick it is: "Cleaning up 0.8 s".
  public func waitingLabel(elapsed: Double, locale: Locale = .current) -> String {
    "\(self == .cleaningUp ? "Cleaning up" : "Transcribing") \(Self.seconds(elapsed, locale: locale))"
  }

  /// What the suggestion bar says for a moment once the text is in: "Done in 1.4 s".
  public static func doneLabel(elapsed: Double, locale: Locale = .current) -> String { "Done in \(seconds(elapsed, locale: locale))" }

  /// Seconds in tenths, with the locale's decimal mark ("0.8 s", "0,8 s"); rounded down, so the ticking
  /// count never runs ahead of the clock.
  static func seconds(_ s: Double, locale: Locale) -> String {
    let tenths = (max(0, s) * 10).rounded(.down) / 10
    return "\(tenths.formatted(.number.precision(.fractionLength(1)).locale(locale))) s"
  }
}

/// The microphone the app records from, as the keyboard and the app show it (beside a mic icon) while dictating.
struct Microphone: Equatable, Sendable {
  /// What iOS calls the input ("iPhone Microphone", "Headset Microphone").
  let name: String
}

/// The wire between keyboard and app: Darwin notifications (no payload) plus App Group defaults for the
/// state, a heartbeat and the finished text. Each request and result carries an id so a late or repeated
/// notification is ignored.
enum DictationChannel {
  static let start = "es.luischav.v2t.dictation.start"
  static let stop = "es.luischav.v2t.dictation.stop"
  static let changed = "es.luischav.v2t.dictation.changed"
  static let stateKey = "dictation.state"
  static let heartbeatKey = "dictation.heartbeat"
  static let resultKey = "dictation.result"
  /// The id of the keyboard request the result answers (the request id the app saw when recording began).
  static let resultIdKey = "dictation.resultId"
  static let requestIdKey = "dictation.requestId"
  /// The last result id a keyboard typed, so a result is typed once, even by a keyboard attached later.
  static let deliveredIdKey = "dictation.deliveredId"
  /// The field the result belongs in (UITextDocumentProxy.documentIdentifier), stamped when the keyboard asks
  /// for a dictation and again when it stops one, so a keyboard opened in another field never types it.
  static let requestDocumentKey = "dictation.requestDocument"
  /// The app refreshes the heartbeat every second while warm; older than this means no session.
  static let heartbeatTimeout: TimeInterval = 3
  static let url = URL(string: "v2t://dictate")!
  /// The name of the microphone the warm session records from; empty when no session.
  static let microphoneNameKey = "dictation.microphone"

  static func writeMicrophone(_ mic: Microphone?, to defaults: UserDefaults) {
    defaults.set(mic?.name ?? "", forKey: microphoneNameKey)
  }

  static func readMicrophone(from defaults: UserDefaults) -> Microphone? {
    guard let name = defaults.string(forKey: microphoneNameKey), !name.isEmpty else { return nil }
    return Microphone(name: name)
  }

  /// True while the speech model cannot take a recording: not on the device, failed to load, or loading for the
  /// first time. The mic key then opens the app, which offers the download, Try again, or shows it preparing.
  static let modelMissingKey = "dictation.modelMissing"

  /// The microphone level while listening, newest last, each 0...1, written by the app 20 times a second for
  /// the keyboard's waveform. A file in the App Group rather than defaults, which are not meant for that rate.
  static var levelsFile: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Settings.group)?.appending(path: "dictation-levels.bin")
  }

  static func writeLevels(_ levels: [Float]) {
    guard let url = levelsFile else { return }
    writeLevels(levels, to: url)
  }

  /// Atomic (a temporary file renamed over the old one): a plain write truncates the file first, so the
  /// keyboard, reading on its own timer, caught it empty or half-written and drew a flat waveform for a frame.
  static func writeLevels(_ levels: [Float], to url: URL) {
    try? levels.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url, options: .atomic)
  }

  /// nil when the file could not be read, so the keyboard keeps the waveform it has instead of blanking it.
  static func readLevels() -> [Float]? {
    guard let url = levelsFile else { return nil }
    return readLevels(from: url)
  }

  static func readLevels(from url: URL) -> [Float]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  static func post(_ name: String) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
  }

  /// Observes a Darwin notification on the main queue until the returned token is released.
  static func observe(_ name: String, _ handler: @escaping @MainActor () -> Void) -> DarwinObserver {
    DarwinObserver(name: name, handler: handler)
  }
}

final class DarwinObserver: @unchecked Sendable {
  let name: String
  let handler: @MainActor () -> Void

  init(name: String, handler: @escaping @MainActor () -> Void) {
    self.name = name
    self.handler = handler
    let me = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), me, { _, observer, _, _, _ in
      guard let observer else { return }
      let o = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
      DispatchQueue.main.async { MainActor.assumeIsolated { o.handler() } }
    }, name as CFString, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(name as CFString), nil)
  }
}
