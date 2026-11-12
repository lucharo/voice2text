import Foundation

/// The iCloud merge of the dictionary's entries, as values only: the file's text, the records of the last sync
/// on this device, the records in iCloud and the time go in, the new text and records come out. Each entry is
/// last writer wins, and a deletion is kept as a tombstone (a record with no line) so a device that still has
/// the entry cannot bring it back. Comments, blanks and malformed lines are not entries and stay local.
enum DictionaryMerge {
  /// One entry as synced: its line as stored, nil once deleted, and when this device or another last changed it.
  struct Record: Codable, Equatable, Sendable {
    var line: String?
    var time: Date
  }
  typealias Records = [String: Record]

  /// The file's entries by key; of two lines with one key, the first counts, as the first is what `remove` drops.
  static func entries(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for raw in text.split(whereSeparator: \.isNewline) {
      guard let item = PersonalDictionary.item(raw) else { continue }
      if out[item.key] == nil { out[item.key] = item.line }
    }
    return out
  }

  /// The time of an entry this device had before it ever synced: older than any change made anywhere, so a
  /// deletion or edit already in iCloud wins over it, while an entry iCloud has never seen still goes up.
  static let unversioned = Date.distantPast

  /// The file as records: an entry unchanged since the last sync keeps that sync's time; one added or edited
  /// since (on this device, the keyboard included) and one deleted since (a tombstone) take `now`. With no last
  /// sync (`synced` nil: the first on this device, also after sync was off from the start), every entry is
  /// `unversioned`, since nothing tells an old entry from one just added.
  static func local(_ text: String, synced: Records?, now: Date) -> Records {
    let current = entries(text)
    guard let synced else { return current.mapValues { Record(line: $0, time: unversioned) } }
    var out: Records = [:]
    for (k, line) in current {
      out[k] = synced[k]?.line == line ? synced[k]! : Record(line: line, time: now)
    }
    for (k, record) in synced where current[k] == nil {
      out[k] = record.line == nil ? record : Record(line: nil, time: now)
    }
    return out
  }

  /// Per key, the later record. A tie, as when two devices sync in the same instant, goes to the greater line
  /// (a line over a tombstone), so every device picks the same one.
  static func merge(_ a: Records, _ b: Records) -> Records {
    a.merging(b) { x, y in
      if x.time != y.time { return x.time > y.time ? x : y }
      return (x.line ?? "") >= (y.line ?? "") ? x : y
    }
  }

  /// The file with the merged entries: a line whose entry was deleted goes, one whose entry changed takes the
  /// new line, entries new to this device go at the end, and every other line stays as it is. The text is
  /// returned untouched when its entries already match.
  static func apply(_ records: Records, to text: String) -> String {
    let wanted = records.compactMapValues(\.line)
    guard entries(text) != wanted else { return text }
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    let endsWithNewline = lines.last == ""
    if endsWithNewline { lines.removeLast() }
    var placed = Set<String>()
    var out: [String] = []
    for raw in lines {
      guard let item = PersonalDictionary.item(raw) else { out.append(raw); continue }
      let k = item.key
      guard let line = wanted[k] else { continue }
      // a second line with the same key is the user's own duplicate: left as it is
      out.append(placed.insert(k).inserted && line != item.line ? line : raw)
    }
    let added = wanted.filter { !placed.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
    out += added
    return out.joined(separator: "\n") + (endsWithNewline || !added.isEmpty ? "\n" : "")
  }

  /// The whole merge: the new file text, and the records both this device's sync state and iCloud then hold.
  static func run(text: String, synced: Records?, remote: Records, now: Date) -> (text: String, records: Records) {
    let records = merge(local(text, synced: synced, now: now), remote)
    return (apply(records, to: text), records)
  }
}
