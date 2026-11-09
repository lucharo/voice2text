import CoreGraphics
import Foundation

/// One field of a debug log event, written as JSON.
public enum LogValue: Sendable, Equatable {
  case s(String)
  case i(Int)
  case d(Double)
  case b(Bool)
  /// A point in keyboard coordinates, written as [x, y] to 0.1 pt.
  case pt(CGPoint)
  case list([LogValue])
  case obj([LogField])
  case null
}

/// A named field; events keep their fields in order, so lines read the same way every time.
public struct LogField: Sendable, Equatable {
  public let name: String
  public let value: LogValue
  public init(_ name: String, _ value: LogValue) {
    self.name = name
    self.value = value
  }
}

/// The opt-in keyboard debug log (#162): every touch, key, swipe, suggestion and correction as one JSON line,
/// for working out where the keyboard gets typing wrong. Off unless the app's switch is on, and it switches
/// itself off at the deadline the app set (24 hours after it was turned on).
///
/// The hot path is cheap: `log` appends the event to an in-memory buffer under a lock and returns. The buffer is
/// encoded and appended to the file on a background queue once it holds 64 events or a second after the first
/// one, so a key costs no file access. Each write opens and closes the file, so the app can clear it at any time.
/// Past `maxFileBytes` the file moves to `keyboard.1.jsonl` (replacing the one before), so the log never holds
/// more than twice that.
public final class KeyboardDebugLog: @unchecked Sendable {
  public static let fileName = "keyboard.jsonl"
  public static let rotatedName = "keyboard.1.jsonl"
  /// Written by `clear`: the wall-clock time of the last Clear log. Events from before it that the keyboard still
  /// holds in memory or in its write queue are dropped rather than written to a fresh file.
  public static let clearedName = "cleared"
  /// 4 MB a file, about 40,000 events; two files at most.
  public static let defaultMaxFileBytes = 4 << 20

  public let directory: URL
  public let maxFileBytes: Int
  /// Seconds on the same clock as UITouch timestamps and CACurrentMediaTime (system uptime).
  public let clock: @Sendable () -> TimeInterval
  let flushCount: Int
  let flushDelay: TimeInterval

  private let lock = NSLock()
  private var pending: [Pending] = []
  private var flushScheduled = false
  private var started = false
  private var deadline: TimeInterval = 0
  /// Set while the field is one the log never records (a password or card field), or by the keyboard otherwise.
  private var suspended = false
  private let queue = DispatchQueue(label: "v2t.keyboard-log", qos: .utility)

  private struct Pending {
    /// Seconds of uptime.
    let t: TimeInterval
    /// Wall-clock seconds when it was logged, to compare with the app's Clear log time.
    var wall = Date().timeIntervalSince1970
    let event: String
    let fields: [LogField]
  }

  public init(directory: URL, maxFileBytes: Int = KeyboardDebugLog.defaultMaxFileBytes, flushCount: Int = 64,
              flushDelay: TimeInterval = 1, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.directory = directory
    self.maxFileBytes = maxFileBytes
    self.flushCount = flushCount
    self.flushDelay = flushDelay
    self.clock = clock
  }

  /// True while events are recorded: started, before the deadline, and not suspended.
  public var isOn: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started && !suspended && clock() < deadline
  }

  /// Starts recording until `until` (a wall-clock time, as the app stores it). A time already past leaves it off.
  /// Calling it again with the same deadline changes nothing.
  public func start(until: Date, now: Date = Date()) {
    let remaining = until.timeIntervalSince(now)
    lock.lock()
    let wasOn = started
    started = remaining > 0
    deadline = clock() + remaining
    lock.unlock()
    if wasOn && remaining <= 0 { flush() }
  }

  /// Stops recording and writes what is buffered.
  public func stop() {
    lock.lock()
    started = false
    lock.unlock()
    flush()
  }

  /// Pauses recording without forgetting the deadline (a password field), or resumes it.
  public func suspend(_ on: Bool) {
    lock.lock()
    suspended = on
    lock.unlock()
  }

  /// Records one event, at `t` (seconds of uptime, a touch's own timestamp) or now. Does nothing while off.
  public func log(_ event: String, _ fields: [LogField] = [], at t: TimeInterval? = nil) {
    lock.lock()
    guard started, !suspended else { lock.unlock(); return }
    let now = clock()
    if now >= deadline {
      // the 24 hours are up: one last line says so, then nothing more
      started = false
      pending.append(Pending(t: now, event: "auto-off", fields: []))
      lock.unlock()
      flush()
      return
    }
    pending.append(Pending(t: t ?? now, event: event, fields: fields))
    let full = pending.count >= flushCount
    let schedule = !full && !flushScheduled
    if schedule { flushScheduled = true }
    lock.unlock()
    if full {
      flush()
    } else if schedule {
      queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in self?.write(self?.take() ?? []) }
    }
  }

  /// Hands what is buffered to the writer; `wait` blocks until it is on disk (tests, the keyboard closing).
  public func flush(wait: Bool = false) {
    let batch = take()
    if wait {
      queue.sync { write(batch) }
    } else if !batch.isEmpty {
      queue.async { self.write(batch) }
    }
  }

  private func take() -> [Pending] {
    lock.lock()
    defer { lock.unlock() }
    flushScheduled = false
    let b = pending
    pending = []
    return b
  }

  private func write(_ batch: [Pending]) {
    guard !batch.isEmpty else { return }
    // Clear log and Export (in the app) and this write (in the keyboard) take turns on the folder, so a clear
    // never lands between reading its marker and appending, and an export never sees a rotation half done
    Self.coordinate(directory, writing: true) { appendCoordinated(batch) }
  }

  private func appendCoordinated(_ batch: [Pending]) {
    // events from before the app's last Clear log stay cleared
    let cleared = (try? String(contentsOf: directory.appending(path: Self.clearedName), encoding: .utf8)).flatMap(Double.init) ?? 0
    var out = ""
    out.reserveCapacity(batch.count * 96)
    for p in batch where p.wall > cleared {
      out += "{\"t\":"
      Self.number(p.t * 1000, decimals: 1, into: &out)
      out += ",\"e\":"
      Self.string(p.event, into: &out)
      for f in p.fields {
        out += ","
        Self.string(f.name, into: &out)
        out += ":"
        Self.value(f.value, into: &out)
      }
      out += "}\n"
    }
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: Self.fileName)
    if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
    guard !out.isEmpty, let h = try? FileHandle(forWritingTo: file) else { return }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.write(contentsOf: Data(out.utf8))
    try? h.close()
    if Int(size) + out.utf8.count > maxFileBytes {
      let rotated = directory.appending(path: Self.rotatedName)
      try? fm.removeItem(at: rotated)
      try? fm.moveItem(at: file, to: rotated)
    }
  }

  // MARK: files, for the app

  /// The log's files, oldest first, those that exist.
  public static func files(in directory: URL) -> [URL] {
    [rotatedName, fileName].map { directory.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Bytes on disk.
  public static func size(in directory: URL) -> Int {
    files(in: directory).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
  }

  public static func clear(in directory: URL, now: Date = Date()) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    coordinate(directory, writing: true) {
      try? String(now.timeIntervalSince1970).write(to: directory.appending(path: clearedName), atomically: true, encoding: .utf8)
      for f in files(in: directory) { try? FileManager.default.removeItem(at: f) }
    }
  }

  /// Both files joined, oldest first: what Export shares, read while the keyboard cannot rotate them.
  public static func merged(in directory: URL) throws -> Data {
    var result: Result<Data, Error> = .success(Data())
    coordinate(directory, writing: false) {
      result = Result { try files(in: directory).reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) } }
    }
    return try result.get()
  }

  /// Runs `body` with the folder to itself across processes (NSFileCoordinator, as PersonalDictionary does for the
  /// dictionary): writers one at a time, readers apart from writers. Without a coordinator it runs anyway.
  static func coordinate(_ directory: URL, writing: Bool, _ body: () -> Void) {
    var error: NSError?
    var ran = false
    if writing {
      NSFileCoordinator().coordinate(writingItemAt: directory, options: .forMerging, error: &error) { _ in ran = true; body() }
    } else {
      NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &error) { _ in ran = true; body() }
    }
    if !ran { body() }
  }


  // MARK: helpers

  /// At most `limit` points spread evenly along the trace, the first and last kept.
  public static func sample(_ points: [CGPoint], limit: Int) -> [CGPoint] {
    guard points.count > limit, limit >= 2 else { return points }
    return (0..<limit).map { points[Int((Double($0) * Double(points.count - 1) / Double(limit - 1)).rounded())] }
  }

  // MARK: JSON

  static func value(_ v: LogValue, into out: inout String) {
    switch v {
    case .s(let s): string(s, into: &out)
    case .i(let i): out += String(i)
    case .d(let d): number(d, decimals: 3, into: &out)
    case .b(let b): out += b ? "true" : "false"
    case .pt(let p):
      out += "["
      number(Double(p.x), decimals: 1, into: &out)
      out += ","
      number(Double(p.y), decimals: 1, into: &out)
      out += "]"
    case .list(let l):
      out += "["
      for (i, x) in l.enumerated() {
        if i > 0 { out += "," }
        value(x, into: &out)
      }
      out += "]"
    case .obj(let fields):
      out += "{"
      for (i, f) in fields.enumerated() {
        if i > 0 { out += "," }
        string(f.name, into: &out)
        out += ":"
        value(f.value, into: &out)
      }
      out += "}"
    case .null: out += "null"
    }
  }

  static func number(_ d: Double, decimals: Int, into out: inout String) {
    guard d.isFinite else { out += "null"; return }
    let scale = pow(10, Double(decimals)), r = (d * scale).rounded() / scale
    if r == r.rounded(), abs(r) < 1e15 { out += String(Int(r)) } else { out += String(r) }
  }

  static func string(_ s: String, into out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
      default: out.unicodeScalars.append(u)
      }
    }
    out += "\""
  }
}
