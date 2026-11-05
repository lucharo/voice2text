import Foundation

public enum DictationState: String, Sendable {
  /// The app's mic session is warm: the mic key records without leaving the host app.
  case idle
  /// No warm session: the mic key opens v2t once to start one.
  case needsApp
  case listening
  case transcribing
  /// The keyboard has no Full Access, so it cannot talk to the app.
  case unavailable
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

  /// The microphone level while listening, newest last, each 0...1, written by the app 20 times a second for
  /// the keyboard's waveform. A file in the App Group rather than defaults, which are not meant for that rate.
  static var levelsFile: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Settings.group)?.appending(path: "dictation-levels.bin")
  }

  static func writeLevels(_ levels: [Float]) {
    guard let url = levelsFile else { return }
    try? levels.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
  }

  static func readLevels() -> [Float] {
    guard let url = levelsFile, let data = try? Data(contentsOf: url) else { return [] }
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
