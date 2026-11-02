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

  var entries: (terms: [String], replacements: [(heard: String, written: String)]) {
    var terms: [String] = [], reps: [(String, String)] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if let r = line.range(of: "=>") {
        let heard = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let written = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if !heard.isEmpty, !written.isEmpty { reps.append((heard, written)) }
      } else {
        terms.append(line)
      }
    }
    return (terms, reps)
  }

  var terms: [String] { entries.terms }

  /// Every word the keyboard should treat as known: terms and the written side of replacements.
  var keyboardWords: [String] {
    let e = entries
    return (e.terms + e.replacements.map(\.written)).flatMap { $0.split(separator: " ").map(String.init) }
  }

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
