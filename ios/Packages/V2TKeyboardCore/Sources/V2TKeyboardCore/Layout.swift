import CoreGraphics
import Foundation

public enum KeyAction: Hashable, Sendable {
  case character(String)
  case shift, delete, space, returnKey, mic, emoji
  case page(KeyboardPage)
}

public enum KeyboardPage: Hashable, Sendable { case letters, numbers, symbols }

public struct Key: Hashable, Sendable, Identifiable {
  public let id: String
  public let action: KeyAction
  public let label: String
  public var frame: CGRect
  /// Long-press alternatives, the most likely first (Apple's order for the language).
  public let alternatives: [String]
  public let row: Int

  public var isCharacter: Bool { if case .character = action { true } else { false } }
  public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

public enum KeyboardLanguage: String, CaseIterable, Sendable {
  case english = "en", spanish = "es"
}

/// Key geometry in points for one keyboard width, modelled on Apple's portrait iPhone keyboard: ten keys on
/// the top row, 6 pt gaps, 3 pt side margins, a 54 pt row pitch. Hit-testing gives every touch a key: gaps
/// belong to the nearest key, so no tap is lost.
public struct KeyboardLayout: Sendable {
  public static let sideInset: CGFloat = 3
  public static let gap: CGFloat = 6
  public static let keyHeight: CGFloat = 42
  public static let rowPitch: CGFloat = 54
  public static let topInset: CGFloat = 8
  public static var height: CGFloat { topInset + 4 * rowPitch - (rowPitch - keyHeight) + 4 }

  public let width: CGFloat
  public let page: KeyboardPage
  public let language: KeyboardLanguage
  public let keys: [Key]
  /// Centre of each letter key by folded byte (a-z), for the swipe decoder and the tap corrector.
  public let letterCenters: [CGPoint?]

  public var unitWidth: CGFloat { (width - 2 * Self.sideInset - 9 * Self.gap) / 10 }

  public init(width: CGFloat, page: KeyboardPage = .letters, language: KeyboardLanguage = .english) {
    self.width = width
    self.page = page
    self.language = language
    let keys = Self.build(width: width, page: page, language: language)
    self.keys = keys
    var centers = [CGPoint?](repeating: nil, count: 128)
    for k in keys where page == .letters {
      if case .character(let c) = k.action, let b = c.unicodeScalars.first, c.unicodeScalars.count == 1, (0x61...0x7A).contains(b.value) {
        centers[Int(b.value)] = k.center
      }
    }
    self.letterCenters = centers
  }

  static func y(_ row: Int) -> CGFloat { topInset + CGFloat(row) * rowPitch }

  static func build(width: CGFloat, page: KeyboardPage, language: KeyboardLanguage) -> [Key] {
    let u = (width - 2 * sideInset - 9 * gap) / 10
    var keys: [Key] = []
    func charRow(_ row: Int, _ chars: [String], leading: CGFloat) {
      for (i, c) in chars.enumerated() {
        let x = leading + CGFloat(i) * (u + gap)
        keys.append(Key(id: "\(page)-\(c)", action: .character(c), label: c, frame: CGRect(x: x, y: y(row), width: u, height: keyHeight),
                        alternatives: alternatives(c, language), row: row))
      }
    }
    func centred(_ n: Int) -> CGFloat { (width - (CGFloat(n) * u + CGFloat(n - 1) * gap)) / 2 }
    let side = 1.3 * u + 0.5 * gap  // shift / delete
    switch page {
    case .letters:
      charRow(0, "qwertyuiop".map(String.init), leading: sideInset)
      let home = language == .spanish ? "asdfghjklñ" : "asdfghjkl"
      charRow(1, home.map(String.init), leading: centred(home.count))
      let bottom = "zxcvbnm".map(String.init)
      charRow(2, bottom, leading: centred(bottom.count))
      keys.append(Key(id: "shift", action: .shift, label: "shift", frame: CGRect(x: sideInset, y: y(2), width: side, height: keyHeight), alternatives: [], row: 2))
    case .numbers:
      charRow(0, "1234567890".map(String.init), leading: sideInset)
      charRow(1, ["-", "/", ":", ";", "(", ")", language == .spanish ? "€" : "$", "&", "@", "\""], leading: sideInset)
      charRow(2, [".", ",", "?", "!", "'"], leading: centred(5))
      keys.append(Key(id: "symbols", action: .page(.symbols), label: "#+=", frame: CGRect(x: sideInset, y: y(2), width: side, height: keyHeight), alternatives: [], row: 2))
    case .symbols:
      charRow(0, ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], leading: sideInset)
      charRow(1, ["_", "\\", "|", "~", "<", ">", language == .spanish ? "$" : "€", "£", "¥", "•"], leading: sideInset)
      charRow(2, [".", ",", "?", "!", "'"], leading: centred(5))
      keys.append(Key(id: "numbers", action: .page(.numbers), label: "123", frame: CGRect(x: sideInset, y: y(2), width: side, height: keyHeight), alternatives: [], row: 2))
    }
    keys.append(Key(id: "delete", action: .delete, label: "delete", frame: CGRect(x: width - sideInset - side, y: y(2), width: side, height: keyHeight), alternatives: [], row: 2))

    // bottom row as Apple's iOS 27 keyboard: page switch, next keyboard, space, mic, return
    let small = 1.2 * u, ret = 1.6 * u
    var x = sideInset
    let pageKey: (KeyAction, String) = page == .letters ? (.page(.numbers), "123") : (.page(.letters), "ABC")
    for (id, action, label, w) in [("page", pageKey.0, pageKey.1, small), ("emoji", KeyAction.emoji, "next keyboard", small)] {
      keys.append(Key(id: id, action: action, label: label, frame: CGRect(x: x, y: y(3), width: w, height: keyHeight), alternatives: [], row: 3))
      x += w + gap
    }
    let micX = width - sideInset - ret - gap - small
    keys.append(Key(id: "space", action: .space, label: language == .spanish ? "espacio" : "space", frame: CGRect(x: x, y: y(3), width: micX - gap - x, height: keyHeight), alternatives: [], row: 3))
    keys.append(Key(id: "mic", action: .mic, label: "mic", frame: CGRect(x: micX, y: y(3), width: small, height: keyHeight), alternatives: [], row: 3))
    keys.append(Key(id: "return", action: .returnKey, label: language == .spanish ? "intro" : "return", frame: CGRect(x: width - sideInset - ret, y: y(3), width: ret, height: keyHeight), alternatives: [], row: 3))
    return keys
  }

  /// The key a touch at `p` belongs to: its row by the midpoint between rows, then the horizontally nearest
  /// key in that row.
  public func key(at p: CGPoint) -> Key? {
    let row = max(0, min(3, Int(((p.y - Self.topInset + (Self.rowPitch - Self.keyHeight) / 2) / Self.rowPitch).rounded(.down))))
    var best: Key?, bestD = CGFloat.infinity
    for k in keys where k.row == row {
      let d = p.x < k.frame.minX ? k.frame.minX - p.x : (p.x > k.frame.maxX ? p.x - k.frame.maxX : 0)
      if d < bestD { bestD = d; best = k }
    }
    return best
  }


  static func alternatives(_ c: String, _ lang: KeyboardLanguage) -> [String] {
    // Apple's long-press sets; the language's own letter leads.
    switch c {
    case "a": lang == .spanish ? ["á", "à", "ä", "â", "ã", "å", "ā", "æ", "ª"] : ["à", "á", "â", "ä", "æ", "ã", "å", "ā"]
    case "e": lang == .spanish ? ["é", "è", "ë", "ê", "ę", "ė", "ē"] : ["è", "é", "ê", "ë", "ē", "ė", "ę"]
    case "i": lang == .spanish ? ["í", "ï", "ì", "î", "į", "ī"] : ["î", "ï", "í", "ī", "į", "ì"]
    case "o": lang == .spanish ? ["ó", "ò", "ö", "ô", "õ", "ø", "ō", "œ", "º"] : ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"]
    case "u": lang == .spanish ? ["ú", "ü", "ù", "û", "ū"] : ["û", "ü", "ù", "ú", "ū"]
    case "n": ["ñ", "ń"]
    case "c": ["ç", "ć", "č"]
    case "s": ["ß", "ś", "š"]
    case "y": ["ÿ"]
    case "z": ["ž", "ź", "ż"]
    case "l": ["ł"]
    case "?": ["¿"]
    case "!": ["¡"]
    case "'": ["’", "‘", "`"]
    case "\"": ["”", "“", "„", "«", "»"]
    case "-": ["–", "—", "•"]
    case "$", "€": ["$", "€", "£", "¥", "₩", "₽", "¢"].filter { $0 != c }
    case ".": ["…"]
    default: []
    }
  }
}
