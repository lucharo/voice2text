import Foundation

/// One finished dictation, kept on the device only.
struct Dictation: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var text: String
  /// What the recogniser heard, kept when cleanup or the dictionary changed it.
  var heard: String? = nil
  var date: Date
  var language: String
  /// How long it took, kept since #123; nil for dictations saved before that.
  var timings: DictationTimings? = nil
}

/// How long one dictation took after Done, in seconds (#123).
struct DictationTimings: Codable, Equatable, Sendable {
  /// Length of the recording.
  var audio: Double
  /// From Done to the transcript (only the last piece, when the rest was transcribed while talking).
  var speech: Double
  /// Apple Intelligence's cleanup; nil when cleanup did not run.
  var cleanup: Double?
  /// From Done to the text being sent to the keyboard, dictionary included.
  var total: Double
  /// Pieces transcribed while recording (#112).
  var piecesWhileRecording: Int = 0

  /// One line for History: "Ready in 1.4 s · speech 0.1 s, cleanup 1.2 s · 45 s spoken".
  var summary: String {
    func s(_ x: Double) -> String { x < 10 ? String(format: "%.1f s", x) : String(format: "%.0f s", x) }
    var parts = ["speech \(s(speech))"]
    if let cleanup { parts.append("cleanup \(s(cleanup))") }
    return "Ready in \(s(total)) · \(parts.joined(separator: ", ")) · \(s(audio)) spoken"
  }
}

/// Past dictations, newest first, saved as one JSON file. A missing or unreadable file starts an empty
/// history rather than failing the launch; the unreadable file is kept beside it for inspection.
@MainActor final class History: ObservableObject {
  @Published private(set) var items: [Dictation] = []
  let file: URL

  init(file: URL = History.defaultFile) {
    self.file = file
    guard let data = try? Data(contentsOf: file) else { return }
    do {
      items = try JSONDecoder.v2t.decode([Dictation].self, from: data)
    } catch {
      try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
    }
  }

  func add(_ d: Dictation) throws {
    items.insert(d, at: 0)
    try save()
  }

  func delete(_ id: Dictation.ID) throws {
    items.removeAll { $0.id == id }
    try save()
  }

  /// Deletes every dictation and the file that held them.
  func clear() throws {
    items = []
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
  }

  /// The bytes the history file takes; dictations are kept as text only, never audio.
  var bytes: Int64 {
    let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
    return Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
  }

  private func save() throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder.v2t.encode(items).write(to: file, options: [.atomic, .completeFileProtection])
  }

  static var defaultFile: URL {
    URL.applicationSupportDirectory.appending(path: "history.json")
  }
}

extension JSONEncoder {
  static let v2t: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

extension JSONDecoder {
  static let v2t: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
