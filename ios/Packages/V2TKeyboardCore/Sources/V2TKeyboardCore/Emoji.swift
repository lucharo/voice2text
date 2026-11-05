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
