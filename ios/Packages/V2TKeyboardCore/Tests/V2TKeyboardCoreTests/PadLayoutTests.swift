import CoreGraphics
import Testing
@testable import V2TKeyboardCore

/// The iPad form, at the widths of the iPads that run iPadOS 26: mini (744 pt portrait), 11-inch (820 and
/// 834), 13-inch (1024 and 1032) in portrait, and 1133 to 1376 in landscape.
struct PadLayoutTests {
  static let portrait: [CGFloat] = [744, 820, 834, 1024, 1032]
  static let landscape: [CGFloat] = [1133, 1180, 1194, 1366, 1376]
  static var all: [KeyboardLayout] {
    var out: [KeyboardLayout] = []
    for (widths, land) in [(portrait, false), (landscape, true)] {
      for w in widths {
        for page in [KeyboardPage.letters, .numbers, .symbols] {
          for lang in KeyboardLanguage.allCases { out.append(KeyboardLayout(width: w, page: page, language: lang, form: .pad, landscape: land)) }
        }
      }
    }
    return out
  }

  func row(_ l: KeyboardLayout, _ r: Int) -> [Key] { l.keys.filter { $0.row == r }.sorted { $0.frame.minX < $1.frame.minX } }

  @Test func rowsFollowApplesIPadKeyboard() {
    let en = KeyboardLayout(width: 834, form: .pad)
    #expect(row(en, 0).map(\.label) == "qwertyuiop".map(String.init) + ["delete"])
    #expect(row(en, 1).map(\.label) == "asdfghjkl".map(String.init) + ["return"])
    #expect(row(en, 2).map(\.label) == ["shift"] + "zxcvbnm,.".map(String.init) + ["shift"])
    #expect(row(en, 3).map(\.id) == ["emoji", "page", "mic", "space", "page-right", "dismiss"])
    let es = KeyboardLayout(width: 834, language: .spanish, form: .pad)
    #expect(row(es, 1).map(\.label) == "asdfghjklñ".map(String.init) + ["intro"])
  }

  @Test func everyKeyFitsEdgeToEdgeWithoutOverlapAtEveryIPadWidth() {
    for l in Self.all {
      for r in 0..<4 {
        let keys = row(l, r)
        // each row ends at the right margin, with one gap between neighbours
        #expect(abs(keys.last!.frame.maxX - (l.width - l.metrics.sideInset)) < 0.5, "\(l.width) \(l.page) row \(r)")
        for (a, b) in zip(keys, keys.dropFirst()) {
          #expect(abs(b.frame.minX - a.frame.maxX - l.metrics.gap) < 0.5, "\(l.width) \(a.id) | \(b.id)")
        }
        if r == 2 {  // nine keys between the two page keys on every page, so the right one keeps Apple's width
          #expect(abs(keys.last!.frame.width - 1.45 * l.unitWidth) < 0.5, "\(l.width) \(l.page) right key \(keys.last!.frame.width)")
        }
        for k in keys {
          #expect(k.frame.minX >= 0, "\(k.id)")
          #expect(k.frame.width >= l.unitWidth - 0.5, "\(l.width) \(l.page) \(k.id) is narrower than a letter key")
          #expect(k.frame.maxY <= l.height, "\(k.id)")
        }
      }
    }
  }

  @Test func keyIdsAreUniqueAndBothShiftsShift() {
    for l in Self.all {
      #expect(Set(l.keys.map(\.id)).count == l.keys.count, "\(l.width) \(l.page)")
    }
    let en = KeyboardLayout(width: 1194, form: .pad, landscape: true)
    #expect(en.keys.filter { $0.action == .shift }.map(\.id) == ["shift", "shift-right"])
    #expect(en.keys.contains { $0.action == .dismiss })
  }

  @Test func landscapeKeysAreTallerAndEveryLetterHasACentre() {
    let p = KeyboardLayout(width: 834, form: .pad), l = KeyboardLayout(width: 1194, form: .pad, landscape: true)
    #expect(l.metrics.keyHeight > p.metrics.keyHeight && l.height > p.height)
    for c in "abcdefghijklmnopqrstuvwxyz".unicodeScalars { #expect(p.letterCenters[Int(c.value)] != nil, "\(c)") }
  }

  @Test func gapsAndMarginsHitTheNearestKey() {
    let l = KeyboardLayout(width: 834, form: .pad)
    let q = l.keys.first { $0.label == "q" }!, a = l.keys.first { $0.label == "a" }!
    #expect(l.key(at: CGPoint(x: 0.5, y: q.frame.midY))?.label == "q")
    #expect(l.key(at: CGPoint(x: 0.5, y: a.frame.midY))?.label == "a")  // the indent belongs to a
    #expect(l.key(at: CGPoint(x: l.width - 1, y: a.frame.midY))?.label == "return")
    #expect(l.key(at: CGPoint(x: q.frame.midX, y: q.frame.maxY + l.metrics.gap / 2 - 1))?.label == "q")
  }

  @Test func punctuationKeysOfferTheirShiftedMarks() {
    let l = KeyboardLayout(width: 834, form: .pad)
    #expect(l.keys.first { $0.id == "letters-," }?.alternatives == ["!"])
    #expect(l.keys.first { $0.id == "letters-." }?.alternatives.first == "?")
  }

  @Test func thePhoneFormIsUnchanged() {
    let l = KeyboardLayout(width: 402)
    #expect(l.form == .phone && l.metrics == .phone && l.height == 8 + 4 * 54 - 12 + 4)
    #expect(l.keys.contains { $0.id == "return" } && !l.keys.contains { $0.action == .dismiss })
  }
}
