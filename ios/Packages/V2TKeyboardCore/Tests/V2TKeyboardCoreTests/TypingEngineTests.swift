import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

final class FakeProxy: TextProxy {
  var text = ""
  var documentContextBeforeInput: String? { text }
  func insertText(_ t: String) { text += t }
  func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

struct TypingEngineTests {
  let layout = KeyboardLayout(width: 402, language: .english)

  func engine(_ start: String = "") throws -> (TypingEngine, FakeProxy) {
    let p = FakeProxy()
    p.text = start
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: layout))
    e.resync()
    return (e, p)
  }

  /// Types each character as a tap at its key's centre; " " is the space bar.
  func type(_ s: String, _ e: TypingEngine, start: TimeInterval = 0) {
    var t = start
    for ch in s {
      t += 1  // a second apart: never a double tap
      if ch == " " { e.space(now: t); continue }
      let key = layout.keys.first { $0.label == String(ch).lowercased() }
      e.character(String(ch).lowercased(), at: key?.center, now: t)
    }
  }

  @Test func firstLetterOfTheFieldAndOfEachSentenceIsCapitalised() throws {
    let (e, p) = try engine()
    type("hello there. how are you? fine", e)
    #expect(p.text == "Hello there. How are you? Fine")
  }

  @Test func shiftCapitalisesOneLetterAndDoubleTapLocks() throws {
    let (e, p) = try engine("x ")
    e.shiftTap(now: 10)
    type("ok", e, start: 10)
    #expect(p.text == "x Ok")
    e.shiftTap(now: 20)
    e.shiftTap(now: 20.2)
    #expect(e.shift == .locked)
    type("ok", e, start: 20.2)
    #expect(p.text == "x OkOK")
  }

  /// A rotation mid-word: the touches were on the old layout, so they must not be scored against the new
  /// one. Typed on the iPad portrait layout, then the keyboard turns to landscape before the space.
  @Test func aLayoutChangeMidWordDropsTheOldTouchesAndKeepsTheWord() throws {
    let lex = try Fixtures.english.get()
    let portrait = KeyboardLayout(width: 834, form: .pad), landscape = KeyboardLayout(width: 1194, form: .pad, landscape: true)
    let p = FakeProxy()
    p.text = "I said "
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [lex], layout: portrait))
    e.resync()
    for (i, ch) in "teh".enumerated() {
      e.character(String(ch), at: portrait.keys.first { $0.label == String(ch) }?.center, now: Double(i + 1))
    }
    #expect(e.composing.allSatisfy { $0.point != nil })
    e.replaceLayout(with: Suggester(lexicons: [lex], layout: landscape))
    #expect(e.composing.map(\.character) == Array("teh") && e.composing.allSatisfy { $0.point == nil })
    #expect(p.text == "I said teh")
    e.space(now: 10)
    #expect(p.text == "I said the ")  // still corrected, from the letters alone
  }

  /// Numbers page for an apostrophe, then back to letters at the same width: the letters did not move, so
  /// the word keeps its touch points and off-centre taps are still corrected spatially.
  @Test func aPageSwitchToTheSameLettersKeepsTheTouches() throws {
    let lex = try Fixtures.english.get()
    let e = TypingEngine(proxy: FakeProxy(), suggester: Suggester(lexicons: [lex], layout: layout))
    e.resync()
    for (i, ch) in "dont".enumerated() {
      let c = layout.keys.first { $0.label == String(ch) }!.center
      e.character(String(ch), at: CGPoint(x: c.x + 4, y: c.y - 3), now: Double(i + 1))  // a little off centre
    }
    let before = e.composing
    e.replaceLayout(with: Suggester(lexicons: [lex], layout: KeyboardLayout(width: 402, language: .english)))
    #expect(e.composing == before && e.composing.allSatisfy { $0.point != nil })
  }

  @Test func spaceAutocorrectsAndDeleteOffersTheOriginalBack() throws {
    let (e, p) = try engine("I said ")
    type("teh ", e)
    #expect(p.text == "I said the ")
    e.delete()
    #expect(p.text == "I said the")
    #expect(e.suggestions().first?.word == "teh")
    e.pick("teh")
    #expect(p.text == "I said teh ")
    #expect(e.learned.contains("teh"))
    type("teh ", e)
    #expect(p.text == "I said teh teh ")  // learned: no longer corrected
  }

  /// The bar bolds pendingAutocorrection: the word a space would put in, never one a learned word or a field
  /// without autocorrect keeps as typed.
  @Test func pendingAutocorrectionIsWhatSpaceWouldDo() throws {
    let (e, _) = try engine("I said ")
    type("teh", e)
    #expect(e.pendingAutocorrection == "the")
    e.learned.insert("teh")
    #expect(e.pendingAutocorrection == nil)
    let (f, _) = try engine("I said ")
    f.traits = FieldTraits(autocorrect: false)
    type("teh", f)
    #expect(f.pendingAutocorrection == nil)
  }

  @Test func doubleSpaceEndsTheSentence() throws {
    let (e, p) = try engine("Hi ")
    type("there", e)
    e.space(now: 100)
    e.space(now: 100.2)
    #expect(p.text == "Hi there. ")
    #expect(e.shift == .on)
  }

  @Test func slowSecondSpaceIsJustASpace() throws {
    let (e, p) = try engine("Hi ")
    type("there", e)
    e.space(now: 100)
    e.space(now: 101)
    #expect(p.text == "Hi there  ")
  }

  @Test func punctuationAfterAPickedSuggestionPullsTheSpaceBack() throws {
    let (e, p) = try engine("See you ")
    type("tomor", e)
    e.pick("tomorrow")
    #expect(p.text == "See you tomorrow ")
    e.character(".")
    #expect(p.text == "See you tomorrow. ")
  }

  @Test func swipedWordsAreSpacedAndAlternativesReplaceThem() throws {
    let (e, p) = try engine("Hi")
    e.swipe(["there", "three"])
    #expect(p.text == "Hi there")
    #expect(e.suggestions().map(\.word) == ["three"])
    e.pick("three")
    #expect(p.text == "Hi three ")
    e.swipe(["friends"])
    e.swipe(["now"])
    #expect(p.text == "Hi three friends now")
  }

  @Test func aLetterAfterASwipeStartsANewWord() throws {
    let (e, p) = try engine("Hi")
    e.swipe(["there"])
    type("x", e)
    #expect(p.text == "Hi there x")
  }

  @Test func deleteWordRemovesTheWordBeforeTheCursorAndItsSpaces() throws {
    let (e, p) = try engine("one two  ")
    e.deleteWord()
    #expect(p.text == "one ")
    e.deleteWord()
    #expect(p.text == "")
  }

  @Test func resyncReadsTheWordAtTheCursorForSuggestions() throws {
    let (e, _) = try engine("I like keyb")
    #expect(e.composing.map(\.character) == Array("keyb"))
    #expect(e.suggestions().map(\.word).contains("keyboard"))
  }

  @Test func fieldsWithoutAutocorrectKeepTheTypo() throws {
    let (e, p) = try engine("x ")
    e.traits = FieldTraits(capitalization: .none, autocorrect: false)
    type("teh ", e)
    #expect(p.text == "x teh ")
  }

  @Test func dictatedTextLandsAsItsOwnWords() throws {
    let (e, p) = try engine("Note:")
    e.insertFinished("buy milk")
    #expect(p.text == "Note: buy milk")
  }

  /// ß uppercases to two letters: with shift on it types "SS" and keeps both in the word (it used to crash).
  @Test func shiftedEszettTypesTwoLetters() throws {
    let (e, p) = try engine("x ")
    e.shiftTap(now: 10)
    e.character("ß", now: 10.5)
    #expect(p.text == "x SS")
    #expect(e.composing.count == 2)
    e.delete()
    #expect(p.text == "x S" && e.composing.count == 1)
  }

  @Test func capsLockAndAllCapitalFieldsSwipeWholeWordsInCapitals() throws {
    let (e, p) = try engine("x ")
    e.capsLockTap()
    e.swipe(["hello", "jello"])
    #expect(p.text == "x HELLO")
    #expect(e.suggestions().map(\.word) == ["JELLO"])
    let (f, q) = try engine()
    f.traits = FieldTraits(capitalization: .all)
    f.resync()
    f.swipe(["hello"])
    f.swipe(["there"])
    #expect(q.text == "HELLO THERE")
    let (g, r) = try engine("x ")
    g.shiftTap(now: 10)
    g.swipe(["hello", "jello"])
    #expect(r.text == "x Hello")
    #expect(g.suggestions().map(\.word) == ["Jello"])
  }

  /// Back at the end of "4teh", the word is read with its digit, so space does not turn it into "4the".
  @Test func resyncKeepsDigitsSoSpaceLeavesTheWordAlone() throws {
    let (e, p) = try engine("x 4teh")
    #expect(e.composing.count == 4)
    e.space(now: 50)
    #expect(p.text == "x 4teh ")
  }

  /// A correction made at a full stop stays when a space follows (a sentence end) and is undone when a letter
  /// follows (an address: "exmaple.com").
  @Test func aLetterAfterTheFullStopUndoesItsCorrection() throws {
    let (e, p) = try engine("I saw ")
    type("teh", e)
    e.character(".", now: 50)
    #expect(p.text == "I saw the.")
    type(" ok", e, start: 60)
    #expect(p.text == "I saw the. Ok")
    let (f, q) = try engine("see ")
    type("exmaple", f)
    f.character(".", now: 50)
    #expect(q.text == "see example.")
    type("com ", f, start: 60)
    #expect(q.text == "see exmaple.com ")
  }

  /// A curly apostrophe from the long press stays inside the word, as the straight one does.
  @Test func aCurlyApostropheDoesNotEndTheWord() throws {
    let (e, p) = try engine("x ")
    type("teh", e)
    e.character("’", now: 100)
    #expect(e.composing.count == 4)
    #expect(p.text == "x teh’")
    p.text = "x don’"
    e.resync()
    #expect(e.composing.count == 4)
  }
}
