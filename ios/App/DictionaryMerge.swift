import Foundation

/// The iCloud merge of the dictionary's entries, as values only: the file's text, the records of the last sync
/// on this device, the records in iCloud and the time go in, the new text and records come out. Each entry is
/// last writer wins, and a deletion is kept as a tombstone (a record with no line) so a device that still has
/// the entry cannot bring it back. Comments, blanks and malformed lines are not entries and stay local.
enum DictionaryMerge {
  /// One entry as synced: its line as stored, nil once deleted, when this device or another last changed it, and
  /// where that change came from (nil for an entry a device had before its first sync).
  struct Record: Codable, Equatable, Sendable {
    var line: String?
    var time: Date
    var source: Source? = nil
  }
  typealias Records = [String: Record]

  /// The device that made a change, by its hardware model ("iPhone17,1"), and whether the "keyboard" or the "app"
  /// made it there.
  struct Source: Codable, Equatable, Sendable {
    var device: String
    var app: String
  }

  /// The file's entries by key; of two lines with one key, the first counts, as the first is what `remove` drops.
  static func entries(_ text: String) -> [String: String] { PersonalDictionary.entryLines(text) }

  /// The time of an entry this device had before it ever synced: older than any change made anywhere, so a
  /// deletion or edit already in iCloud wins over it, while an entry iCloud has never seen still goes up.
  static let unversioned = Date.distantPast

  /// The file as records: an entry unchanged since the last sync keeps that sync's record; one added, edited or
  /// deleted since (a tombstone) takes the time and program of its `changes` entry, from when it was made, with
  /// this `device` as its source. A difference with no change behind it is a download whose sync state was never
  /// written, so it is `unversioned` and loses to whatever iCloud holds. With no last sync (`synced` nil: the
  /// first on this device, also after sync was off from the start), every entry is `unversioned`, since nothing
  /// tells an old entry from one just added.
  static func local(_ text: String, synced: Records?, changes: [String: PersonalDictionary.Change], device: String) -> Records {
    let current = entries(text)
    let record = { (k: String, line: String?) in
      changes[k].map { Record(line: line, time: $0.time, source: Source(device: device, app: $0.by)) }
        ?? Record(line: line, time: unversioned)
    }
    guard let synced else {
      return current.mapValues { Record(line: $0, time: unversioned) }
    }
    var out: Records = [:]
    for (k, line) in current {
      out[k] = synced[k]?.line == line ? synced[k]! : record(k, line)
    }
    for (k, old) in synced where current[k] == nil {
      out[k] = old.line == nil ? old : record(k, nil)
    }
    return out
  }

  /// Per key, the later record. A tie, as when two devices sync in the same instant or both had the entry before
  /// their first sync, goes to the greater line (a line over a tombstone), then the greater source, so every
  /// device picks the same one.
  static func merge(_ a: Records, _ b: Records) -> Records {
    a.merging(b) { x, y in
      if x.time != y.time { return x.time > y.time ? x : y }
      let rank = { (r: Record) in [r.line ?? "", r.source?.device ?? "", r.source?.app ?? ""] }
      return rank(x).lexicographicallyPrecedes(rank(y)) ? y : x
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
  static func run(text: String, synced: Records?, remote: Records, changes: [String: PersonalDictionary.Change],
                  device: String) -> (text: String, records: Records) {
    let records = merge(local(text, synced: synced, changes: changes, device: device), remote)
    return (apply(records, to: text), records)
  }
}
