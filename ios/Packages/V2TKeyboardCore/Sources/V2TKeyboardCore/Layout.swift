import CoreGraphics
import Foundation

public enum KeyAction: Hashable, Sendable {
  case character(String)
  case shift, delete, space, returnKey, mic, emoji
  /// iPad only: hides the keyboard, as Apple's bottom-right key does.
  case dismiss
  case page(KeyboardPage)
}

public enum KeyboardPage: Hashable, Sendable { case letters, numbers, symbols }

/// Which of Apple's keyboards the layout follows: the iPhone one, or the iPad one (delete and return on the
/// right of their rows, a shift at each end, a hide-keyboard key). An iPad's floating keyboard is phone sized
/// and uses `.phone`.
public enum KeyboardForm: Sendable { case phone, pad }

public struct Key: Hashable, Sendable, Identifiable {
  public let id: String
  public let action: KeyAction
  public let label: String
  public var frame: CGRect
  /// Long-press alternatives, the most likely first (Apple's order for the language).
  public let alternatives: [String]
  public let row: Int

  public var isCharacter: Bool { if case .character = action { true } else { false } }
  /// A letter key: only these start a swipe, so dragging off , . or ' still types the mark.
  public var startsSwipe: Bool { if case .character(let c) = action { c.first?.isLetter == true } else { false } }
  public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

public enum KeyboardLanguage: String, CaseIterable, Sendable {
  case english = "en", spanish = "es"
}

/// Key geometry in points for one keyboard width, modelled on Apple's keyboards: four rows, the top row of
/// letters ten keys wide. Hit-testing gives every touch a key: gaps belong to the nearest key, so no tap is
/// lost.
public struct KeyboardLayout: Sendable {
  /// Spacing for one form and orientation; every row has the same pitch.
  public struct Metrics: Sendable, Equatable {
    public let sideInset, gap, keyHeight, rowPitch, topInset, bottomInset: CGFloat
    public var height: CGFloat { topInset + 4 * rowPitch - (rowPitch - keyHeight) + bottomInset }

    /// Apple's portrait iPhone keyboard: 6 pt gaps, 3 pt side margins, a 54 pt row pitch.
    public static let phone = Metrics(sideInset: 3, gap: 6, keyHeight: 42, rowPitch: 54, topInset: 8, bottomInset: 4)
    /// Apple's iPad keyboard, ESTIMATED: about 260 pt of keys in portrait and 345 pt in landscape on an
    /// 11-inch iPad, below the suggestion bar. Not yet checked against a screenshot of Apple's own iPad
    /// keyboard: the installed Simulator runtime (iOS 27.1) offers no iPad device. PadKeyboardUITests'
    /// baseline test captures one when an iPad Simulator or device is available.
    public static let padPortrait = Metrics(sideInset: 5, gap: 10, keyHeight: 53, rowPitch: 63, topInset: 8, bottomInset: 6)
    public static let padLandscape = Metrics(sideInset: 6, gap: 12, keyHeight: 72, rowPitch: 84, topInset: 8, bottomInset: 6)
  }

  public let width: CGFloat
  public let page: KeyboardPage
  public let language: KeyboardLanguage
  public let form: KeyboardForm
  public let metrics: Metrics
  public let keys: [Key]
  /// Width of one letter key.
  public let unitWidth: CGFloat
  /// Centre of each letter key by folded byte (a-z), for the swipe decoder and the tap corrector.
  public let letterCenters: [CGPoint?]

  public var height: CGFloat { metrics.height }

  public init(width: CGFloat, page: KeyboardPage = .letters, language: KeyboardLanguage = .english,
              form: KeyboardForm = .phone, landscape: Bool = false) {
    self.width = width
    self.page = page
    self.language = language
    self.form = form
    let m: Metrics = form == .phone ? .phone : (landscape ? .padLandscape : .padPortrait)
    self.metrics = m
    let (keys, u) = form == .phone ? Self.buildPhone(width: width, page: page, language: language, m: m)
                                   : Self.buildPad(width: width, page: page, language: language, m: m)
    self.keys = keys
    self.unitWidth = u
    var centers = [CGPoint?](repeating: nil, count: 128)
    for k in keys where page == .letters {
      if case .character(let c) = k.action, let b = c.unicodeScalars.first, c.unicodeScalars.count == 1, (0x61...0x7A).contains(b.value) {
        centers[Int(b.value)] = k.center
      }
    }
    self.letterCenters = centers
  }

  /// The characters of each page's three rows, as on the iPhone keyboard (the iPad moves the last of the
  /// numbers and symbols middle rows down, beside its wider return key).
  static func rows(_ page: KeyboardPage, _ language: KeyboardLanguage) -> [[String]] {
    switch page {
    case .letters:
      return ["qwertyuiop", language == .spanish ? "asdfghjklñ" : "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    case .numbers:
      return ["1234567890".map(String.init), ["-", "/", ":", ";", "(", ")", language == .spanish ? "€" : "$", "&", "@", "\""], [".", ",", "?", "!", "'"]]
    case .symbols:
      return [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", language == .spanish ? "$" : "€", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
    }
  }

  /// The row-2 key that switches page, beside the characters (shift on the letters page).
  static func pageSwitch(_ page: KeyboardPage) -> (id: String, action: KeyAction, label: String) {
    switch page {
    case .letters: ("shift", .shift, "shift")
    case .numbers: ("symbols", .page(.symbols), "#+=")
    case .symbols: ("numbers", .page(.numbers), "123")
    }
  }

  static func buildPhone(width: CGFloat, page: KeyboardPage, language: KeyboardLanguage, m: Metrics) -> ([Key], CGFloat) {
    let sideInset = m.sideInset, gap = m.gap, keyHeight = m.keyHeight
    func y(_ row: Int) -> CGFloat { m.topInset + CGFloat(row) * m.rowPitch }
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
    let r = rows(page, language)
    charRow(0, r[0], leading: sideInset)
    charRow(1, r[1], leading: page == .letters ? centred(r[1].count) : sideInset)
    charRow(2, r[2], leading: centred(r[2].count))
    let sw = pageSwitch(page)
    keys.append(Key(id: sw.id, action: sw.action, label: sw.label, frame: CGRect(x: sideInset, y: y(2), width: side, height: keyHeight), alternatives: [], row: 2))
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
    return (keys, u)
  }

  /// Apple's iPad keyboard: an 11.45-unit grid. Top row ten keys and delete; middle row indented, then
  /// return; third row a shift at each end around the letters and , and . ; bottom row next keyboard, page
  /// switch, mic, space, page switch, hide keyboard.
  static func buildPad(width: CGFloat, page: KeyboardPage, language: KeyboardLanguage, m: Metrics) -> ([Key], CGFloat) {
    let s = m.sideInset, g = m.gap, h = m.keyHeight
    func y(_ row: Int) -> CGFloat { m.topInset + CGFloat(row) * m.rowPitch }
    let u = (width - 2 * s - 10 * g) / 11.45
    var keys: [Key] = []
    /// Lays `items` left to right from `x0`; a nil width takes whatever the row has left.
    func row(_ r: Int, from x0: CGFloat, _ items: [(id: String, action: KeyAction, label: String, w: CGFloat?, alts: [String])]) {
      let fixed = items.compactMap(\.w).reduce(0, +)
      let flex = max(u, width - s - x0 - fixed - CGFloat(items.count - 1) * g)
      var x = x0
      for it in items {
        let w = it.w ?? flex
        keys.append(Key(id: it.id, action: it.action, label: it.label, frame: CGRect(x: x, y: y(r), width: w, height: h), alternatives: it.alts, row: r))
        x += w + g
      }
    }
    func chars(_ cs: [String]) -> [(id: String, action: KeyAction, label: String, w: CGFloat?, alts: [String])] {
      cs.map { c in
        let alts: [String] = page == .letters && c == "," ? ["!"] : page == .letters && c == "." ? ["?", "…"] : alternatives(c, language)
        return ("\(page)-\(c)", .character(c), c, u, alts)
      }
    }
    var r = rows(page, language)
    if page != .letters { r[2].append(r[1].removeLast()) }  // the quote or bullet moves down beside the wider return
    // the third row holds nine keys between its two page keys, as the letters row does with , and .
    switch page {
    case .letters: r[2] += [",", "."]
    case .numbers: r[2] += ["%", "*", "#"]
    case .symbols: r[2] += ["…", "°", "§"]
    }
    row(0, from: s, chars(r[0]) + [("delete", .delete, "delete", nil, [])])
    let indent: CGFloat = page == .letters ? (r[1].count == 10 ? 0.2 * u : 0.5 * u) : 0
    row(1, from: s + indent, chars(r[1]) + [("return", .returnKey, language == .spanish ? "intro" : "return", nil, [])])
    let sw = pageSwitch(page)
    row(2, from: s, [(sw.id, sw.action, sw.label, u, [])] + chars(r[2]) + [("\(sw.id)-right", sw.action, sw.label, nil, [])])
    let pageKey: (KeyAction, String) = page == .letters ? (.page(.numbers), ".?123") : (.page(.letters), "ABC")
    row(3, from: s, [
      ("emoji", .emoji, "next keyboard", u, []),
      ("page", pageKey.0, pageKey.1, 1.45 * u, []),
      ("mic", .mic, "mic", u, []),
      ("space", .space, language == .spanish ? "espacio" : "space", nil, []),
      ("page-right", pageKey.0, pageKey.1, 1.45 * u, []),
      ("dismiss", .dismiss, "hide keyboard", 1.45 * u, []),
    ])
    return (keys, u)
  }

  /// The key a touch at `p` belongs to: its row by the midpoint between rows, then the horizontally nearest
  /// key in that row.
  public func key(at p: CGPoint) -> Key? {
    let m = metrics
    let row = max(0, min(3, Int(((p.y - m.topInset + (m.rowPitch - m.keyHeight) / 2) / m.rowPitch).rounded(.down))))
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
