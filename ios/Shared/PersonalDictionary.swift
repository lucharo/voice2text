import Foundation

/// The user's dictionary, in the Mac app's format (v2t/config.py read_dictionary): one entry per line, a
/// `Term` the cleanup must spell exactly, or `heard => written`, a whole-word case-insensitive replacement
/// applied after cleanup. Lines starting with # are ignored. Stored in the App Group so the keyboard never
/// autocorrects a dictionary term away.
final class PersonalDictionary: ObservableObject, @unchecked Sendable {
  static let header = """
  # v2t dictionary: one entry per line. Two kinds:
  #   Term                 a name, product or jargon the recogniser gets wrong
  #   heard => written     an exact replacement applied after cleanup (case-insensitive)

  """

  let file: URL
  /// Which program writes through this copy: "keyboard" in the keyboard extension, "app" otherwise.
  let writer: String
  private let now: () -> Date
  @Published private(set) var text: String

  init(file: URL? = PersonalDictionary.defaultFile, writer: String = Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard" : "app",
       now: @escaping () -> Date = Date.init) {
    let f = file ?? URL.applicationSupportDirectory.appending(path: "dictionary.txt")
    self.file = f
    self.writer = writer
    self.now = now
    text = (try? String(contentsOf: f, encoding: .utf8)) ?? Self.header
  }

  /// When an entry was added, edited or deleted here, and by which program: the iCloud sync's last-writer-wins
  /// goes by these times, not by when the sync ran, so an edit made offline does not beat a later one made
  /// elsewhere. A difference between the file and the sync state with no change behind it is the sync's own
  /// download and never counts as an edit.
  ///
  /// Each change names the line it leaves (nil for a deletion), and a key keeps one change per line: the merge
  /// takes the change whose line is the one on disk, so a write that failed after its change was noted (a full
  /// disk) never dates the line still there, and that line keeps the time it was written.
  struct Change: Codable, Equatable, Sendable {
    var time: Date
    var by: String
    var line: String?
  }

  /// The changes since the app last synced with iCloud, by entry key. Read, written and cleared only inside
  /// `transaction`.
  var changesFile: URL { file.deletingPathExtension().appendingPathExtension("changes.json") }

  var changes: [String: [Change]] {
    (try? JSONDecoder().decode([String: [Change]].self, from: Data(contentsOf: changesFile))) ?? [:]
  }

  static var defaultFile: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Settings.group)?.appending(path: "dictionary.txt")
  }

  /// Reads the file again: the keyboard adds words the user keeps, so a copy loaded earlier may be stale.
  func reload() {
    if let t = try? String(contentsOf: file, encoding: .utf8), t != text { text = t }
  }

  func save(_ newText: String) throws {
    try transaction { try write(newText) }
  }

  /// Saves the "Edit as text" draft, which started as `snapshot`: an unchanged draft writes nothing, lines
  /// another copy added to the file meanwhile (a word kept on the keyboard, an entry from iCloud) are kept at the
  /// end, and lines it removed meanwhile (an entry deleted on another device) stay removed unless the draft
  /// changed them. An entry edited elsewhere is both: its old line goes, its new one is kept. An entry the draft
  /// added, edited or deleted keeps the draft's version, whatever happened to it elsewhere.
  func saveEdit(_ draft: String, from snapshot: String) throws {
    try transaction {
      guard draft != snapshot else { return }
      let lines = { (t: String) in t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }
      let before = Set(lines(snapshot)), mine = Set(lines(draft)), current = Set(lines(text))
      let was = Self.entryLines(snapshot), drafted = Self.entryLines(draft)
      let touched = Set(was.keys).union(drafted.keys).filter { was[$0] != drafted[$0] }
      let isTouched = { (line: String) in Self.item(line).map { touched.contains($0.key) } ?? false }
      let added = lines(text).filter { line in
        !line.isEmpty && !before.contains(line) && !mine.contains(line) && !isTouched(line)
      }
      let removed = before.intersection(mine).subtracting(current).subtracting([""]).filter { !isTouched($0) }
      var t = removed.isEmpty ? draft
        : draft.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
          .filter { !removed.contains($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "\n")
      if !added.isEmpty, !t.isEmpty, !t.hasSuffix("\n") { t += "\n" }
      try write(t + added.map { $0 + "\n" }.joined())
    }
  }

  /// Runs a read-modify-write on the file with the file freshly read and no other process (the keyboard, the
  /// app) writing it meanwhile: NSFileCoordinator serialises writers across processes in the App Group.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { _ in
      reload()
      result = Result { try body() }
    }
    if let e = coordinationError { throw e }
    return try result!.get()
  }

  /// Writes the file; call inside `transaction`. Each entry the write adds, edits or deletes is noted in
  /// `changes` first, unless `asChanges` is false: the app's iCloud sync writes its download that way.
  func write(_ newText: String, asChanges: Bool = true) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    if asChanges {
      let old = Self.entryLines(text), new = Self.entryLines(newText)
      let keys = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
      if !keys.isEmpty {
        var c = changes
        for k in keys { c[k, default: []] = c[k, default: []].filter { $0.line != new[k] } + [Change(time: now(), by: writer, line: new[k])] }
        try JSONEncoder().encode(c).write(to: changesFile, options: .atomic)
      }
    }
    try newText.write(to: file, atomically: true, encoding: .utf8)
    text = newText
  }

  /// One usable line of the file: a term, or a replacement. Comments, blanks and a replacement missing a side
  /// are not items, as in the Mac app.
  struct Item: Identifiable, Equatable {
    enum Kind: Equatable { case term(String), replacement(heard: String, written: String) }
    /// The line as stored, which identifies it for removal.
    let line: String
    let kind: Kind
    var id: String { line }
    /// Lines with one key are one entry, as `addTerm` and `addReplacement` judge duplicates: a term by its text, a
    /// replacement by what is heard, both ignoring case. Only the first line of a key is used, for dictation and
    /// for iCloud sync alike, so a device that downloads the dictionary behaves as the one that wrote it.
    var key: String {
      switch kind {
      case .term(let t): "term:" + t.lowercased()
      case .replacement(let heard, _): "replace:" + heard.lowercased()
      }
    }
  }

  var items: [Item] { text.split(whereSeparator: \.isNewline).compactMap(Self.item) }

  /// One line of the file as an item, nil for a comment, a blank or a replacement missing a side.
  static func item(_ raw: some StringProtocol) -> Item? {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { return nil }
    guard let r = line.range(of: "=>") else { return Item(line: line, kind: .term(line)) }
    let heard = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
    let written = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
    return heard.isEmpty || written.isEmpty ? nil : Item(line: line, kind: .replacement(heard: heard, written: written))
  }

  /// Each entry's line by key; of two lines with one key, the first, as everywhere else.
  static func entryLines(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for raw in text.split(whereSeparator: \.isNewline) {
      guard let item = item(raw) else { continue }
      if out[item.key] == nil { out[item.key] = item.line }
    }
    return out
  }

  var entries: (terms: [String], replacements: [(heard: String, written: String)]) {
    var terms: [String] = [], reps: [(String, String)] = []
    var seen = Set<String>()
    for item in items where seen.insert(item.key).inserted {
      switch item.kind {
      case .term(let t): terms.append(t)
      case .replacement(let h, let w): reps.append((h, w))
      }
    }
    return (terms, reps)
  }

  enum EntryError: LocalizedError, Equatable {
    case empty, arrow, duplicate
    var errorDescription: String? {
      switch self {
      case .empty: "Fill in the empty box first."
      case .arrow: "An entry can't contain =>."
      case .duplicate: "That's already in your dictionary."
      }
    }
  }

  func addTerm(_ term: String) throws {
    let t = term.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { throw EntryError.empty }
    guard !t.contains("=>"), !t.hasPrefix("#") else { throw EntryError.arrow }
    try transaction {
      guard !terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { throw EntryError.duplicate }
      try append(t)
    }
  }

  func addReplacement(heard: String, written: String) throws {
    let h = heard.trimmingCharacters(in: .whitespaces), w = written.trimmingCharacters(in: .whitespaces)
    guard !h.isEmpty, !w.isEmpty else { throw EntryError.empty }
    guard !h.contains("=>"), !w.contains("=>"), !h.hasPrefix("#") else { throw EntryError.arrow }
    try transaction {
      guard !entries.replacements.contains(where: { $0.heard.caseInsensitiveCompare(h) == .orderedSame }) else { throw EntryError.duplicate }
      try append("\(h) => \(w)")
    }
  }

  /// Removes the first line stored exactly as `line` (an `Item.line`), keeping every other line and comment.
  func remove(_ line: String) throws {
    try transaction {
      var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
      guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { return }
      lines.remove(at: i)
      try write(lines.joined(separator: "\n"))
    }
  }

  /// Call inside `transaction`.
  private func append(_ line: String) throws {
    var t = text
    if !t.isEmpty, !t.hasSuffix("\n") { t += "\n" }
    try write(t + line + "\n")
  }

  var terms: [String] { entries.terms }

  /// Every word the keyboard should treat as known: terms and the written side of replacements.
  var keyboardWords: [String] {
    let e = entries
    return (e.terms + e.replacements.map(\.written)).flatMap { $0.split(separator: " ").map(String.init) }
  }

  /// Lowercased dictionary words, for the keyboard to leave uncorrected as it does learned words. Split at
  /// anything but letters, digits and apostrophes, where the keyboard ends a word ("Teh-Code" is "teh", "code").
  var autocorrectExclusions: Set<String> {
    Set(keyboardWords.flatMap { $0.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init) })
  }

  /// Each replacement applies to the text the previous ones left, so their order matters. iCloud sync gives each
  /// device the same rules but not the same file order, so the order is fixed here instead: the longest heard
  /// side first, so "new york => NYC" wins over "york => Yorkshire", then alphabetically.
  func applyReplacements(_ input: String) -> String {
    var out = input
    let ordered = entries.replacements.sorted { a, b in
      a.heard.count != b.heard.count ? a.heard.count > b.heard.count : a.heard.lowercased() < b.heard.lowercased()
    }
    for (heard, written) in ordered {
      let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: heard) + "(?!\\w)"
      guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
      out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: written))
    }
    return out
  }
}
