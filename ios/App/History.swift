import Foundation

/// One finished dictation, kept on the device only.
struct Dictation: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var text: String
  /// What the recogniser heard, kept when cleanup or the dictionary changed it.
  var heard: String? = nil
  var date: Date
  var language: String
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
