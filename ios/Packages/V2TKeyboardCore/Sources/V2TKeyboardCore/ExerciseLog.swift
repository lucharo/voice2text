import Foundation

/// The typing exercise's record (the app's Debugging › Typing exercise): one JSON line per sentence, in the same
/// folder as the keyboard debug log (#162), with the sentence the person was asked to type and what ended up in
/// the field. Its `t` and `end` are on the keyboard log's clock (system uptime, `KeyboardDebugLog.systemClock`),
/// so `ios/tools/kb_log_report.py` and `LogReplayEval` can take the keyboard's events between them and compare
/// what was typed with what was meant. Past `maxFileBytes` the file moves to `exercises.1.jsonl` (replacing the
/// one before), so the record never holds more than twice that. Export and Clear log take these files with the
/// keyboard's (`KeyboardDebugLog.files`).
public enum TypingExerciseLog {
  public static let fileName = "exercises.jsonl"
  public static let rotatedName = "exercises.1.jsonl"
  /// 256 KB a file, about 1,300 sentences; two files at most.
  public static let defaultMaxFileBytes = 256 << 10

  /// One sentence of an exercise.
  public struct Entry: Sendable, Equatable {
    /// The sentence's id in the app's list ("en-07").
    public var id: String
    public var target: String
    /// The field's text when Next was tapped.
    public var typed: String
    /// Seconds of uptime when the sentence appeared, and when Next was tapped.
    public var start: TimeInterval
    public var end: TimeInterval
    /// The clock time when the sentence appeared.
    public var wall: Date

    public init(id: String, target: String, typed: String, start: TimeInterval, end: TimeInterval, wall: Date) {
      self.id = id
      self.target = target
      self.typed = typed
      self.start = start
      self.end = end
      self.wall = wall
    }
  }

  /// The entry as one JSON line, times in milliseconds as the keyboard writes them.
  public static func line(_ e: Entry) -> String {
    var out = "{\"t\":"
    KeyboardDebugLog.number(e.start * 1000, decimals: 1, into: &out)
    out += ",\"e\":\"exercise\",\"end\":"
    KeyboardDebugLog.number(e.end * 1000, decimals: 1, into: &out)
    out += ",\"wall\":"
    KeyboardDebugLog.string(e.wall.ISO8601Format(), into: &out)
    for (name, value) in [("id", e.id), ("target", e.target), ("typed", e.typed)] {
      out += ","
      KeyboardDebugLog.string(name, into: &out)
      out += ":"
      KeyboardDebugLog.string(value, into: &out)
    }
    return out + "}\n"
  }

  /// Appends one entry, taking turns on the folder with the keyboard's writes and the app's Export and Clear log.
  public static func append(_ e: Entry, in directory: URL, maxFileBytes: Int = defaultMaxFileBytes) {
    let data = Data(line(e).utf8)
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    KeyboardDebugLog.coordinate(directory, writing: true) {
      let file = directory.appending(path: fileName)
      if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
      guard let h = try? FileHandle(forWritingTo: file) else { return }
      let size = (try? h.seekToEnd()) ?? 0
      try? h.write(contentsOf: data)
      try? h.close()
      if Int(size) + data.count > maxFileBytes {
        let rotated = directory.appending(path: rotatedName)
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: file, to: rotated)
      }
    }
  }

  /// The words of `target` that ended up different in `typed`, as (target, typed) pairs. Words are compared
  /// with the punctuation around them left out and curly apostrophes read as straight ones, capitals kept (a name
  /// typed in lower case is wrong). With the same number of words they are paired in order; otherwise the whole
  /// sentence is one pair, since which word went missing or was split is a guess. `kb_log_report.py` compares
  /// them the same way.
  public static func wrongWords(target: String, typed: String) -> [(target: String, typed: String)] {
    let t = words(target), y = words(typed)
    guard t.count == y.count else { return t == y ? [] : [(target, typed)] }
    return zip(t, y).filter { $0 != $1 }.map { (target: $0, typed: $1) }
  }

  /// The words of a sentence, without the punctuation around them, curly apostrophes made straight.
  public static func words(_ s: String) -> [String] {
    s.replacingOccurrences(of: "’", with: "'").split(whereSeparator: \.isWhitespace).compactMap { w in
      let trimmed = w.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}
