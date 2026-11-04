import CoreGraphics
import Testing
@testable import V2TKeyboardCore

/// The 13-inch iPad's full keyboard: iPad Pro 13-inch and iPad Air 13-inch (1024 and 1032 pt wide in
/// portrait, 1366 and 1376 in landscape).
struct PadFullLayoutTests {
  static let widths: [(CGFloat, Bool)] = [(1024, false), (1032, false), (1366, true), (1376, true)]

  func row(_ l: KeyboardLayout, _ r: Int) -> [Key] { l.keys.filter { $0.row == r }.sorted { $0.frame.minX < $1.frame.minX } }
  func full(_ w: CGFloat = 1032, _ lang: KeyboardLanguage = .english, page: KeyboardPage = .letters, landscape: Bool = false) -> KeyboardLayout {
    KeyboardLayout(width: w, page: page, language: lang, form: .padFull, landscape: landscape)
  }

  @Test func englishRowsFollowApplesFullKeyboard() {
    let l = full()
    #expect(row(l, 0).map(\.label) == ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "delete"])
    #expect(row(l, 1).map(\.label) == ["tab"] + "qwertyuiop".map(String.init) + ["[", "]", "\\"])
    #expect(row(l, 2).map(\.label) == ["caps lock"] + "asdfghjkl".map(String.init) + [";", "'", "return"])
    #expect(row(l, 3).map(\.label) == ["shift"] + "zxcvbnm".map(String.init) + [",", ".", "/", "shift"])
    #expect(row(l, 4).map(\.id) == ["emoji", "page", "mic", "space", "page-right", "dismiss"])
  }

  @Test func spanishRowsFollowApplesSpanishKeyboardWithoutDeadKeys() {
    let l = full(1032, .spanish)
    #expect(row(l, 0).map(\.label) == ["º", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "'", "¡", "delete"])
    #expect(row(l, 2).map(\.label) == ["caps lock"] + "asdfghjklñç".map(String.init) + ["intro"])
    #expect(row(l, 3).map(\.label) == ["shift", "<"] + "zxcvbnm".map(String.init) + [",", ".", "-", "shift"])
    #expect(!l.keys.contains { $0.label == "´" || $0.label == "`" })
  }

  @Test func shiftTypesTheSecondMarkAndCapsLockOnlyCapitalisesLetters() {
    let key = { (l: KeyboardLayout, label: String) in l.keys.first { $0.label == label }! }
    let en = full(), es = full(1032, .spanish)
    #expect(["1", "2", "-", "/", "'"].map { key(en, $0).output(shift: .on)! } == ["!", "@", "_", "?", "\""])
    #expect(["1", "2", "'", "¡", "<"].map { key(es, $0).output(shift: .on)! } == ["!", "\"", "?", "¿", ">"])
    #expect(key(en, "a").output(shift: .on) == "A" && key(es, "ñ").output(shift: .on) == "Ñ")
    #expect(key(en, "1").output(shift: .locked) == "1" && key(en, "q").output(shift: .locked) == "Q")
    #expect(key(en, "1").output(shift: .off) == "1")
  }

  @Test func everyRowFitsEdgeToEdgeAtEveryThirteenInchWidth() {
    for (w, land) in Self.widths {
      for lang in KeyboardLanguage.allCases {
        let l = full(w, lang, landscape: land)
        #expect(l.metrics.rows == 5 && Set(l.keys.map(\.row)) == [0, 1, 2, 3, 4])
        #expect(Set(l.keys.map(\.id)).count == l.keys.count, "\(w) \(lang)")
        for r in 0..<5 {
          let keys = row(l, r)
          #expect(abs(keys.first!.frame.minX - l.metrics.sideInset) < 0.5, "\(w) row \(r)")
          #expect(abs(keys.last!.frame.maxX - (l.width - l.metrics.sideInset)) < 0.5, "\(w) \(lang) row \(r)")
          for (a, b) in zip(keys, keys.dropFirst()) { #expect(abs(b.frame.minX - a.frame.maxX - l.metrics.gap) < 0.5, "\(a.id) | \(b.id)") }
          for k in keys {
            #expect(k.frame.width >= l.unitWidth - 0.5, "\(w) \(lang) \(k.id) narrower than a letter")
            #expect(k.frame.maxY <= l.height)
          }
        }
      }
    }
  }

  @Test func theKeyboardKeepsItsHeightAcrossPages() {
    for (w, land) in Self.widths {
      let letters = full(w, landscape: land)
      for page in [KeyboardPage.numbers, .symbols] {
        let other = full(w, page: page, landscape: land)
        #expect(abs(other.height - letters.height) < 0.5, "\(w) \(page): \(other.height) vs \(letters.height)")
        #expect(other.form == .padFull && other.keys.contains { $0.action == .dismiss })
      }
    }
  }

  @Test func touchesInTheNumberRowAndBelowHitTheirRow() {
    let l = full()
    let one = l.keys.first { $0.label == "1" }!, q = l.keys.first { $0.label == "q" }!, space = l.keys.first { $0.id == "space" }!
    #expect(l.key(at: one.center)?.label == "1")
    #expect(l.key(at: CGPoint(x: q.frame.midX, y: q.frame.minY - l.metrics.gap / 2 + 1))?.label == "q")
    #expect(l.key(at: CGPoint(x: space.frame.midX, y: l.height - 1))?.id == "space")  // the bottom margin belongs to row 4
    #expect(l.key(at: CGPoint(x: 1, y: q.frame.midY))?.id == "tab")
  }

  @Test func everyLetterHasACentreAndOnlyLettersSwipe() {
    for lang in KeyboardLanguage.allCases {
      let l = full(1032, lang)
      for c in "abcdefghijklmnopqrstuvwxyz".unicodeScalars { #expect(l.letterCenters[Int(c.value)] != nil, "\(c)") }
      #expect(!l.keys.contains { $0.startsSwipe && !$0.label.first!.isLetter })
      #expect(l.keys.first { $0.label == "1" }?.startsSwipe == false)
    }
  }

  @Test func appleUsesTheFullKeyboardOnlyOnThirteenInchIPads() {
    #expect(KeyboardForm.choose(isPad: false, width: 1032, screenShortSide: 1032) == .phone)
    #expect(KeyboardForm.choose(isPad: true, width: 320, screenShortSide: 1032) == .phone)  // floating keyboard
    #expect(KeyboardForm.choose(isPad: true, width: 834, screenShortSide: 834) == .pad)  // 11-inch portrait
    #expect(KeyboardForm.choose(isPad: true, width: 1194, screenShortSide: 834) == .pad)  // 11-inch landscape
    #expect(KeyboardForm.choose(isPad: true, width: 744, screenShortSide: 744) == .pad)  // mini
    #expect(KeyboardForm.choose(isPad: true, width: 1032, screenShortSide: 1032) == .padFull)
    #expect(KeyboardForm.choose(isPad: true, width: 1376, screenShortSide: 1032) == .padFull)
  }

  @Test func capsLockLocksAndUnlocksInOneTapEach() throws {
    let e = TypingEngine(proxy: FakeProxy(), suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: full()))
    e.traits.capitalization = .none
    e.resync()
    e.capsLockTap()
    #expect(e.shift == .locked)
    e.character("a")
    #expect(e.shift == .locked)
    e.capsLockTap()
    #expect(e.shift == .off)
  }
}

/// Review fixes for the full keyboard (roborev 10992).
struct PadFullTypingTests {
  let layout = KeyboardLayout(width: 1032, form: .padFull)
  func key(_ label: String, _ l: KeyboardLayout? = nil) -> Key { (l ?? layout).keys.first { $0.label == label }! }
  func engine(_ start: String = "") throws -> (TypingEngine, FakeProxy) {
    let p = FakeProxy()
    p.text = start
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: layout))
    e.resync()
    return (e, p)
  }

  @Test func automaticCapitalsLeaveNumberKeysAlone() throws {
    let (e, _) = try engine()
    #expect(e.shift == .on && !e.shiftManual)  // an empty field starts a sentence
    #expect(key("1").output(shift: e.shift, manual: e.shiftManual) == "1")
    #expect(key("a").output(shift: e.shift, manual: e.shiftManual) == "A")
    e.shiftTap(now: 10)  // off
    e.shiftTap(now: 20)  // on, by hand
    #expect(e.shift == .on && e.shiftManual)
    #expect(key("1").output(shift: e.shift, manual: e.shiftManual) == "!")
    e.character("!")
    #expect(!e.shiftManual)
  }

  @Test func longPressWithShiftOffersTheShiftedMark() {
    #expect(key("'").longPress(shift: .on, manual: true).first == "\"")
    #expect(key("'").longPress(shift: .on, manual: true).contains("“"))
    #expect(key("/").longPress(shift: .on, manual: true) == ["?", "¿"])
    #expect(key("'").longPress(shift: .off).first == "'")
    #expect(key("e").longPress(shift: .on).first == "E")
  }

  @Test func spanishOrdinalKeyDoesNotStartASwipe() {
    let es = KeyboardLayout(width: 1032, language: .spanish, form: .padFull)
    #expect(key("º", es).startsSwipe == false)
    #expect(key("ñ", es).startsSwipe && key("ç", es).startsSwipe)
  }

  @Test func deleteWordAndSwipesTreatATabAsAGap() throws {
    let (e, p) = try engine("one\tuncharacteristically")
    e.deleteWord()
    #expect(p.text == "one\t")
    let (e2, p2) = try engine("one\t")
    e2.swipe(["two"])
    #expect(p2.text == "one\ttwo")  // no space pushed in after the tab
  }
}
