import Foundation

/// One emoji of the emoji panel, with its five skin-tone variants when it has them (light to dark).
public struct Emoji: Hashable, Sendable {
  public let base: String
  public let skinTones: [String]

  public init(base: String, skinTones: [String] = []) {
    self.base = base
    self.skinTones = skinTones
  }

  /// The emoji with its skin tones and presentation selectors taken out: the same for every variant of one
  /// emoji ("👍🏽" and "👍" share it, as do "☝️" and "☝🏻").
  public static func family(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0F }))
  }
}

/// One category of the emoji panel, in the order of Apple's emoji keyboard.
public struct EmojiCategory: Hashable, Sendable {
  public let id: String
  public let emoji: [Emoji]

  public init(id: String, emoji: [Emoji]) {
    self.id = id
    self.emoji = emoji
  }
}

public enum EmojiData {
  /// Reads the panel's data file (ios/Keyboard/emoji.txt, written by ios/tools/build_emoji.py): "@<category>"
  /// starts a category, and each following line is one emoji, its skin-tone variants after it separated by
  /// commas. Comment lines start with "#".
  public static func parse(_ text: String) -> [EmojiCategory] {
    var out: [EmojiCategory] = []
    var id: String?
    var items: [Emoji] = []
    func close() {
      if let id { out.append(EmojiCategory(id: id, emoji: items)) }
      items = []
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.hasPrefix("#") { continue }
      if line.hasPrefix("@") {
        close()
        id = String(line.dropFirst())
        continue
      }
      guard id != nil else { continue }
      let parts = line.split(separator: ",").map(String.init)
      items.append(Emoji(base: parts[0], skinTones: Array(parts.dropFirst())))
    }
    close()
    return out
  }
}

/// What the user picked in the emoji panel: the recently used emoji, most recent first, and the skin tone
/// last picked for each emoji that has them, which the panel then shows in its place.
public struct EmojiHistory: Equatable, Sendable {
  /// Three columns of Apple's panel on an iPhone.
  public static let recentLimit = 30
  public private(set) var recents: [String]
  /// An emoji's base form -> the skin-tone variant last picked for it.
  public private(set) var tones: [String: String]

  public init(recents: [String] = [], tones: [String: String] = [:]) {
    var seen = Set<String>(), kept: [String] = []
    for r in recents where seen.insert(Emoji.family(r)).inserted { kept.append(r) }
    self.recents = Array(kept.prefix(Self.recentLimit))
    self.tones = tones
  }

  /// `emoji` was typed, picked from `item` (nil when the item is not known, as for a recent whose family is
  /// gone from the data): it moves to the front of the recents, replacing any other skin tone of itself,
  /// and becomes the tone `item` is shown in.
  public mutating func use(_ emoji: String, from item: Emoji?) {
    let family = Emoji.family(emoji)
    recents.removeAll { Emoji.family($0) == family }
    recents.insert(emoji, at: 0)
    if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    if let item, !item.skinTones.isEmpty {
      if item.skinTones.contains(emoji) { tones[item.base] = emoji } else if emoji == item.base { tones[item.base] = nil }
    }
  }

  /// What the panel shows for `item`: the skin tone last picked for it, else its base form.
  public func shown(_ item: Emoji) -> String { tones[item.base] ?? item.base }
}

/// One language's emoji keywords (ios/Keyboard/emoji-keywords-<lang>.txt, written by ios/tools/build_emoji.py): one line per
/// folded keyword, a tab, then the emoji it names, best first; lines sorted by the keyword's UTF-8 bytes. The
/// file stays memory-mapped and is binary-searched, so only an offset per line (about 32 KB) is kept in memory.
public struct EmojiIndex: @unchecked Sendable {
  private let data: Data
  /// Where each keyword line starts and ends (its newline, or the end of the file).
  private let starts: [Int]
  private let ends: [Int]

  public init(data: Data) {
    self.data = data
    var starts: [Int] = [], ends: [Int] = []
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
      var i = 0
      while i < buf.count {
        let lineStart = i
        while i < buf.count, buf[i] != 0x0A { i += 1 }
        if i > lineStart, buf[lineStart] != 0x23 { starts.append(lineStart); ends.append(i) }  // "#" comments
        i += 1
      }
    }
    self.starts = starts
    self.ends = ends
  }

  public init(contentsOf url: URL) throws {
    self.init(data: try Data(contentsOf: url, options: .alwaysMapped))
  }

  public var count: Int { starts.count }

  /// A word as the keywords are written: lowercase, accents and ñ folded.
  public static func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
      .trimmingCharacters(in: .whitespaces)
  }

  /// Line `i` as keyword bytes and the emoji after the tab.
  private func line(_ i: Int) -> (key: ArraySlice<UInt8>, emoji: [String]) {
    let bytes = [UInt8](data[starts[i]..<ends[i]])
    guard let tab = bytes.firstIndex(of: 0x09) else { return (bytes[...], []) }
    let rest = String(decoding: bytes[(tab + 1)...], as: UTF8.self)
    return (bytes[..<tab], rest.split(separator: " ").map(String.init))
  }

  private func key(_ i: Int) -> ArraySlice<UInt8> {
    let end = ends[i]
    return data.withUnsafeBytes { buf in
      var j = starts[i]
      while j < end, buf[j] != 0x09 { j += 1 }
      return ArraySlice(buf[starts[i]..<j])
    }
  }

  /// The first line whose keyword is not less than `q` (bytewise).
  private func lowerBound(_ q: [UInt8]) -> Int {
    var lo = 0, hi = count
    while lo < hi {
      let mid = (lo + hi) / 2
      if key(mid).lexicographicallyPrecedes(q) { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// The emoji a whole word names, best first ("pizza" gives 🍕 first); a plural ending in "s" falls back to
  /// its singular ("pizzas", "perros"). Empty when it names none.
  public func emoji(for word: String) -> [String] {
    let folded = Self.fold(word)
    let exact = exactly(folded)
    if !exact.isEmpty || !folded.hasSuffix("s") || folded.count < 4 { return exact }
    return exactly(String(folded.dropLast()))
  }

  private func exactly(_ folded: String) -> [String] {
    let q = Array(folded.utf8)
    guard !q.isEmpty else { return [] }
    let i = lowerBound(q)
    guard i < count, Array(key(i)) == q else { return [] }
    return line(i).emoji
  }

  /// Emoji for a search: the keyword typed so far first, then keywords it begins, in order; with several
  /// words and no keyword that begins with all of them ("happy cat"), the emoji every word finds.
  public func search(_ query: String, limit: Int = 60) -> [String] {
    let folded = Self.fold(query)
    guard !folded.isEmpty else { return [] }
    var out: [String] = [], seen = Set<String>()
    func add(_ list: [String]) {
      for e in list where out.count < limit && seen.insert(e).inserted { out.append(e) }
    }
    for i in prefixRange(folded) { add(line(i).emoji); if out.count >= limit { break } }
    let words = folded.split(separator: " ").map(String.init)
    if out.isEmpty, words.count > 1 {
      var common: [String]? = nil
      for w in words {
        var found: [String] = [], s = Set<String>()
        for i in prefixRange(w) { for e in line(i).emoji where s.insert(e).inserted { found.append(e) } }
        common = common.map { prev in prev.filter { s.contains($0) } } ?? found
      }
      add(common ?? [])
    }
    return out
  }

  /// A search across several languages' keywords, the first language's emoji first.
  public static func search(_ query: String, in indexes: [EmojiIndex], limit: Int = 60) -> [String] {
    var out: [String] = [], seen = Set<String>()
    for i in indexes {
      for e in i.search(query, limit: limit) where out.count < limit && seen.insert(e).inserted { out.append(e) }
    }
    return out
  }

  /// The lines whose keyword begins with `prefix`.
  private func prefixRange(_ prefix: String) -> Range<Int> {
    let q = Array(prefix.utf8)
    let lo = lowerBound(q)
    var hi = lo
    while hi < count, key(hi).starts(with: q) { hi += 1 }
    return lo..<hi
  }
}
