import CoreGraphics
import Testing
@testable import V2TKeyboardCore

struct LayoutTests {
  let en = KeyboardLayout(width: 402, language: .english)
  let es = KeyboardLayout(width: 402, language: .spanish)

  func labels(_ l: KeyboardLayout, row: Int) -> [String] {
    l.keys.filter { $0.row == row && $0.isCharacter }.sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
  }

  @Test func englishLettersFollowQwerty() {
    #expect(labels(en, row: 0) == "qwertyuiop".map(String.init))
    #expect(labels(en, row: 1) == "asdfghjkl".map(String.init))
    #expect(labels(en, row: 2) == "zxcvbnm".map(String.init))
  }

  @Test func spanishHomeRowEndsWithEnye() {
    #expect(labels(es, row: 1) == "asdfghjklñ".map(String.init))
  }

  @Test func everyKeyFitsInsideTheKeyboardWithoutOverlap() {
    for l in [en, es, KeyboardLayout(width: 402, page: .numbers), KeyboardLayout(width: 375, page: .symbols)] {
      for k in l.keys {
        #expect(k.frame.minX >= 0 && k.frame.maxX <= l.width && k.frame.maxY <= l.height, "\(k.id)")
        for o in l.keys where o.id != k.id { #expect(!k.frame.insetBy(dx: 0.5, dy: 0.5).intersects(o.frame), "\(k.id) overlaps \(o.id)") }
      }
    }
  }

  @Test func touchesInGapsAndMarginsStillHitTheNearestKey() {
    let q = en.keys.first { $0.label == "q" }!, w = en.keys.first { $0.label == "w" }!
    #expect(en.key(at: CGPoint(x: 0.5, y: q.frame.midY))?.label == "q")  // left margin
    #expect(en.key(at: CGPoint(x: q.frame.maxX + 2, y: q.frame.midY))?.label == "q")  // gap, nearer q
    #expect(en.key(at: CGPoint(x: w.frame.minX - 2, y: w.frame.minY - 4))?.label == "w")  // gap above the row
    #expect(en.key(at: CGPoint(x: q.frame.midX, y: q.frame.maxY + 5))?.label == "q")  // row gap, upper half
    #expect(en.key(at: CGPoint(x: q.frame.midX, y: q.frame.maxY + 7))?.label == "a")  // row gap, lower half
  }

  @Test func currencyAndLongPressFollowTheLanguage() {
    #expect(KeyboardLayout(width: 402, page: .numbers, language: .spanish).keys.contains { $0.label == "€" })
    #expect(KeyboardLayout(width: 402, page: .numbers, language: .english).keys.contains { $0.label == "$" })
    #expect(es.keys.first { $0.label == "e" }?.alternatives.first == "é")
    #expect(es.keys.first { $0.label == "n" }?.alternatives.first == "ñ")
  }
}
