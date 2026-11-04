// Python `str` semantics the cleanup guard depends on, on Unicode scalars (Python indexes code points and
// compares them exactly; Swift's String compares by canonical equivalence, so "café" in NFC and NFD would
// be one word here and two in Python).

/// A string as Python sees it: a sequence of code points, compared exactly.
typealias PyStr = [Unicode.Scalar]

extension String {
  var py: PyStr { Array(unicodeScalars) }
  init(py: some Sequence<Unicode.Scalar>) {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: py)
    self.init(view)
  }
}

enum Py {
  /// `str.isspace()`, which is also what `str.split()`, `str.strip()` and `re`'s `\s` use: Unicode
  /// White_Space plus the four information separators U+001C to U+001F (bidi class B or S). Listed from
  /// CPython 3.13 by brute force over every code point.
  static let whitespace: Set<UInt32> = [
    0x9, 0xA, 0xB, 0xC, 0xD, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002,
    0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
  ]

  static func isSpace(_ s: Unicode.Scalar) -> Bool { whitespace.contains(s.value) }

  /// `re`'s `\w` on a str pattern: `str.isalnum()` (a letter, or any Numeric_Type) or the underscore.
  /// Accented letters and ñ are letters; combining marks are not.
  static func isWord(_ s: Unicode.Scalar) -> Bool {
    if s == "_" { return true }
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return s.properties.numericType != nil
    }
  }

  /// `str.isdigit()` on one code point: Numeric_Type Decimal or Digit ("²" is a digit, "½" is not).
  static func isDigit(_ s: Unicode.Scalar) -> Bool {
    let type = s.properties.numericType
    return type == .decimal || type == .digit
  }

  /// `str.isupper()` on one code point.
  static func isUpper(_ s: Unicode.Scalar) -> Bool {
    let p = s.properties
    return p.isUppercase && !p.isLowercase && p.generalCategory != .titlecaseLetter
  }

  /// `str.islower()` on one code point.
  static func isLower(_ s: Unicode.Scalar) -> Bool {
    let p = s.properties
    return p.isLowercase && !p.isUppercase && p.generalCategory != .titlecaseLetter
  }

  /// `str.split()` with no arguments: runs of whitespace separate, no empty words.
  static func split(_ text: PyStr) -> [PyStr] {
    var words: [PyStr] = [], current: PyStr = []
    for s in text {
      if isSpace(s) {
        if !current.isEmpty { words.append(current); current = [] }
      } else {
        current.append(s)
      }
    }
    if !current.isEmpty { words.append(current) }
    return words
  }

  static func split(_ text: String) -> [String] { split(text.py).map { String(py: $0) } }

  /// `str.strip()` with no arguments.
  static func strip(_ text: PyStr) -> PyStr {
    guard let first = text.firstIndex(where: { !isSpace($0) }), let last = text.lastIndex(where: { !isSpace($0) })
    else { return [] }
    return Array(text[first...last])
  }

  static func strip(_ text: String) -> String { String(py: strip(text.py)) }

  /// `str.lower()`: full case mapping per code point, with capital sigma becoming final sigma (ς) at the
  /// end of a word, as CPython's `handle_capital_sigma` decides it.
  static func lower(_ text: PyStr) -> PyStr {
    var out: PyStr = []
    for (i, s) in text.enumerated() {
      if s.value == 0x3A3 {
        out.append(Unicode.Scalar(finalSigma(text, at: i) ? 0x3C2 : 0x3C3)!)
      } else {
        out.append(contentsOf: s.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return out
  }

  private static func finalSigma(_ text: PyStr, at i: Int) -> Bool {
    var j = i - 1
    while j >= 0 && text[j].properties.isCaseIgnorable { j -= 1 }
    guard j >= 0 && text[j].properties.isCased else { return false }
    j = i + 1
    while j < text.count && text[j].properties.isCaseIgnorable { j += 1 }
    return j == text.count || !text[j].properties.isCased
  }

  /// `str.upper()` of one code point (full mapping: "ß" -> "SS").
  static func upper(_ s: Unicode.Scalar) -> PyStr { Array(s.properties.uppercaseMapping.unicodeScalars) }

  /// The match of `re.compile("[<chars>]+$").search(text)` on a word with no whitespace: the longest run
  /// of `chars` that ends the text, as (start offset, run), or nil when the text does not end in one.
  static func trailingRun(_ text: PyStr, of chars: Set<Unicode.Scalar>) -> (start: Int, run: PyStr)? {
    var start = text.count
    while start > 0 && chars.contains(text[start - 1]) { start -= 1 }
    return start < text.count ? (start, Array(text[start...])) : nil
  }
}
