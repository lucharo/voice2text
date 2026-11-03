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
  @Published private(set) var text: String

  init(file: URL? = PersonalDictionary.defaultFile) {
    let f = file ?? URL.applicationSupportDirectory.appending(path: "dictionary.txt")
    self.file = f
    text = (try? String(contentsOf: f, encoding: .utf8)) ?? Self.header
  }

  static var defaultFile: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Settings.group)?.appending(path: "dictionary.txt")
  }

  func save(_ newText: String) throws {
    text = newText
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try newText.write(to: file, atomically: true, encoding: .utf8)
  }

  /// One usable line of the file: a term, or a replacement. Comments, blanks and a replacement missing a side
  /// are not items, as in the Mac app.
  struct Item: Identifiable, Equatable {
    enum Kind: Equatable { case term(String), replacement(heard: String, written: String) }
    /// The line as stored, which identifies it for removal.
    let line: String
    let kind: Kind
    var id: String { line }
  }

  var items: [Item] {
    text.split(whereSeparator: \.isNewline).compactMap { raw in
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { return nil }
      guard let r = line.range(of: "=>") else { return Item(line: line, kind: .term(line)) }
      let heard = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
      let written = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
      return heard.isEmpty || written.isEmpty ? nil : Item(line: line, kind: .replacement(heard: heard, written: written))
    }
  }

  var entries: (terms: [String], replacements: [(heard: String, written: String)]) {
    var terms: [String] = [], reps: [(String, String)] = []
    for item in items {
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
    guard !terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { throw EntryError.duplicate }
    try append(t)
  }

  func addReplacement(heard: String, written: String) throws {
    let h = heard.trimmingCharacters(in: .whitespaces), w = written.trimmingCharacters(in: .whitespaces)
    guard !h.isEmpty, !w.isEmpty else { throw EntryError.empty }
    guard !h.contains("=>"), !w.contains("=>"), !h.hasPrefix("#") else { throw EntryError.arrow }
    guard !entries.replacements.contains(where: { $0.heard.caseInsensitiveCompare(h) == .orderedSame }) else { throw EntryError.duplicate }
    try append("\(h) => \(w)")
  }

  /// Removes the first line stored exactly as `line` (an `Item.line`), keeping every other line and comment.
  func remove(_ line: String) throws {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { return }
    lines.remove(at: i)
    try save(lines.joined(separator: "\n"))
  }

  private func append(_ line: String) throws {
    var t = text
    if !t.isEmpty, !t.hasSuffix("\n") { t += "\n" }
    try save(t + line + "\n")
  }

  var terms: [String] { entries.terms }

  /// Every word the keyboard should treat as known: terms and the written side of replacements.
  var keyboardWords: [String] {
    let e = entries
    return (e.terms + e.replacements.map(\.written)).flatMap { $0.split(separator: " ").map(String.init) }
  }

  /// Lowercased dictionary words, for the keyboard to leave uncorrected as it does learned words.
  var autocorrectExclusions: Set<String> { Set(keyboardWords.map { $0.lowercased() }) }

  func applyReplacements(_ input: String) -> String {
    var out = input
    for (heard, written) in entries.replacements {
      let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: heard) + "(?!\\w)"
      guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
      out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: written))
    }
    return out
  }
}
