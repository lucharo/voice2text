import Foundation

/// One of the five skin tones (Unicode's Fitzpatrick modifiers), light to dark.
public enum SkinTone: Int, CaseIterable, Sendable {
  case light = 1, mediumLight, medium, mediumDark, dark

  /// The modifier character, U+1F3FB to U+1F3FF.
  public var modifier: String { String(UnicodeScalar(0x1F3FA + UInt32(rawValue))!) }

  /// The tone of a modifier, nil for any other scalar.
  public init?(scalar: Unicode.Scalar) {
    guard (0x1F3FB...0x1F3FF).contains(scalar.value) else { return nil }
    self.init(rawValue: Int(scalar.value) - 0x1F3FA)
  }
}

/// One emoji of the emoji panel, with its five skin-tone variants when it has them (light to dark), and for
/// an emoji of two people (handshake, holding hands, kiss, couple with heart) the pattern of its mixed-tone
/// forms, as Apple's keyboard lets each person have their own tone.
public struct Emoji: Hashable, Sendable {
  public let base: String
  public let skinTones: [String]
  /// The mixed-tone form with "*" for each person's skin tone, in order ("🫱*‍🫲*"); nil for one person.
  public let pair: String?

  public init(base: String, skinTones: [String] = [], pair: String? = nil) {
    self.base = base
    self.skinTones = skinTones
    self.pair = pair
  }

  /// The emoji with its skin tones and presentation selectors taken out: the same for every variant of one
  /// emoji ("👍🏽" and "👍" share it, as do "☝️" and "☝🏻").
  public static func family(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0F }))
  }

  /// The variant in `tone`, or the base form for nil (yellow).
  public func variant(_ tone: SkinTone?) -> String {
    guard let tone, skinTones.count == 5 else { return base }
    return skinTones[tone.rawValue - 1]
  }

  /// Two people in their own tones: the same-tone variant when they match ("🤝🏽"), else the mixed form
  /// ("🫱🏻‍🫲🏿"). Nil when this emoji has no mixed form.
  public func variant(_ first: SkinTone, _ second: SkinTone) -> String? {
    guard let pair else { return nil }
    if first == second { return variant(first) }
    return Self.fill(pair, [first, second])
  }

  /// Each person of a two-person emoji alone, in `tone`, for the two-tone picker's rows: "🫱🏽" and "🫲🏽" for 🤝,
  /// "👩🏽" and "👨🏽" for 👫.
  public func people(_ tone: SkinTone) -> [String] {
    guard let pair else { return [] }
    // by scalar throughout: "*" and the joiner after it are one Character, as is "❤️‍💋‍👨"
    return pair.unicodeScalars.split(separator: "*", omittingEmptySubsequences: false).dropLast().map { part in
      // the person is what comes before the tone, after the last joiner
      let person = part.split(separator: "\u{200D}").last ?? part
      return String(String.UnicodeScalarView(person)) + tone.modifier
    }
  }

  /// The skin tones in `s`, in order, when it is a variant of this emoji: [] for the base, one for a
  /// same-tone variant, two for a mixed form. Nil when `s` is not this emoji.
  public func tones(of s: String) -> [SkinTone]? {
    if s == base { return [] }
    if let i = skinTones.firstIndex(of: s) { return [SkinTone(rawValue: i + 1)!] }
    guard let pair else { return nil }
    let t = s.unicodeScalars.compactMap(SkinTone.init(scalar:))
    guard t.count == 2, Self.fill(pair, t) == s else { return nil }
    return t
  }

  /// Every family this emoji's variants have: its base's, and its mixed form's when that differs ("🫱‍🫲"
  /// for 🤝, "👩‍🤝‍👨" for 👫), so a recent in any variant finds it.
  public var families: [String] {
    let f = Self.family(base)
    guard let pair else { return [f] }
    let p = Self.family(String(String.UnicodeScalarView(pair.unicodeScalars.filter { $0 != "*" })))
    return p == f ? [f] : [f, p]
  }

  /// `pattern` with its "*"s replaced by `tones` in order, by scalar ("*" and a joiner after it are one
  /// Character, so String search would not find it).
  private static func fill(_ pattern: String, _ tones: [SkinTone]) -> String {
    var out = String.UnicodeScalarView(), next = tones.makeIterator()
    for s in pattern.unicodeScalars {
      if s == "*", let t = next.next() { out.append(contentsOf: t.modifier.unicodeScalars) } else { out.append(s) }
    }
    return String(out)
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
  /// commas, then for two people "|" and the pattern of their mixed tones. Comment lines start with "#".
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
      let halves = line.split(separator: "|", maxSplits: 1)
      let parts = halves[0].split(separator: ",").map(String.init)
      items.append(Emoji(base: parts[0], skinTones: Array(parts.dropFirst()), pair: halves.count > 1 ? String(halves[1]) : nil))
    }
    close()
    return out
  }

  /// The emoji that have skin tones, by every family of their variants (`Emoji.families`): how emoji search,
  /// the suggestion bar and the recents find the emoji behind a string. About 340 entries.
  public static func toned(_ categories: [EmojiCategory]) -> [String: Emoji] {
    var out: [String: Emoji] = [:]
    for c in categories { for e in c.emoji where !e.skinTones.isEmpty { for f in e.families { out[f] = e } } }
    return out
  }
}

/// What the user picked in the emoji panel: the recently used emoji, most recent first, the skin tone last
/// picked for each emoji that has them, and the default skin tone, which every emoji with tones is shown in
/// until a tone is picked for it. Apple's keyboard keeps the per-emoji tone only; a default is Gboard's.
public struct EmojiHistory: Equatable, Sendable {
  /// Three columns of Apple's panel on an iPhone.
  public static let recentLimit = 30
  public private(set) var recents: [String]
  /// An emoji's base form -> the variant last picked for it, when that differs from the default (the base
  /// form itself when yellow was picked over a default tone).
  public private(set) var tones: [String: String]
  /// The tone every emoji with skin tones is shown in until one is picked for it; nil is yellow.
  public private(set) var defaultTone: SkinTone?

  public init(recents: [String] = [], tones: [String: String] = [:], defaultTone: SkinTone? = nil) {
    var seen = Set<String>(), kept: [String] = []
    for r in recents where seen.insert(Emoji.family(r)).inserted { kept.append(r) }
    self.recents = Array(kept.prefix(Self.recentLimit))
    self.tones = tones
    self.defaultTone = defaultTone
  }

  /// `emoji` was typed, picked from `item` (nil when the item is not known, as for a recent whose family is
  /// gone from the data): it moves to the front of the recents, replacing any other skin tone of itself,
  /// and becomes the tone `item` is shown in.
  public mutating func use(_ emoji: String, from item: Emoji?) {
    let families = Set(item?.families ?? [Emoji.family(emoji)]).union([Emoji.family(emoji)])
    recents.removeAll { families.contains(Emoji.family($0)) }
    recents.insert(emoji, at: 0)
    if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    if let item, !item.skinTones.isEmpty, item.tones(of: emoji) != nil {
      tones[item.base] = emoji == item.variant(defaultTone) ? nil : emoji
    }
  }

  /// What the panel shows for `item`: the tone last picked for it, else the default tone, else its base form.
  public func shown(_ item: Emoji) -> String { tones[item.base] ?? item.variant(defaultTone) }

  /// An emoji as search and the suggestion bar offer it (they list base forms): in the tone `shown` gives,
  /// found through `toned` (`EmojiData.toned`). Any other emoji comes back as it is.
  public func shown(_ emoji: String, toned: [String: Emoji]) -> String {
    guard let item = toned[Emoji.family(emoji)], emoji == item.base else { return emoji }
    return shown(item)
  }
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

/// The default skin tone as the app's keyboard settings store it in the App Group: the tone (nil is yellow)
/// and when it was chosen, so the keyboard knows to drop per-emoji tones picked before it.
public struct StoredSkinTone: Equatable, Sendable {
  public static let toneKey = "emojiSkinTone", dateKey = "emojiSkinToneDate"
  public var tone: SkinTone?
  /// Seconds since 1970.
  public var date: Double

  public init(tone: SkinTone?, date: Double) {
    self.tone = tone
    self.date = date
  }

  /// The tone kept in `defaults`, nil when none was ever chosen there.
  public init?(_ defaults: UserDefaults) {
    guard defaults.object(forKey: Self.dateKey) != nil else { return nil }
    self.init(tone: SkinTone(rawValue: defaults.integer(forKey: Self.toneKey)), date: defaults.double(forKey: Self.dateKey))
  }

  public func save(to defaults: UserDefaults) {
    defaults.set(tone?.rawValue ?? 0, forKey: Self.toneKey)
    defaults.set(date, forKey: Self.dateKey)
  }
}
