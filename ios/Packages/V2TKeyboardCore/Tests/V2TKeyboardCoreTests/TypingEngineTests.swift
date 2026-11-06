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

  /// A text replacement expands like a correction, and delete offers the shortcut back.
  @Test func aTextReplacementExpandsAndReverts() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["omw": "On my way!"]
    type("omw", e)
    #expect(e.pendingAutocorrection == "On my way!")
    type(" ", e, start: 10)
    #expect(p.text == "ok On my way! ")
    e.delete()
    #expect(e.suggestions().first?.word == "omw")
    e.pick("omw")
    #expect(p.text == "ok omw ")
  }

  /// After delete offers the shortcut back, the phrase is not a word being typed: space leaves it alone,
  /// and the bar shows the phrase beside the shortcut before it expands.
  @Test func aReplacementPhraseIsNotRetypedAsAWord() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["aw": "a way"]
    type("aw", e)
    #expect(e.suggestions().prefix(2).map(\.word) == ["aw", "a way"])
    type(" ", e, start: 10)
    #expect(p.text == "ok a way ")
    e.delete()
    #expect(e.composing.isEmpty && e.suggestions().first?.word == "aw")
    type(" ", e, start: 20)
    #expect(p.text == "ok a way ")
  }

  /// A shortcut the user put back is learned, so it no longer expands.
  @Test func aRejectedReplacementStopsExpanding() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["omw": "On my way!"]
    type("omw ", e)
    e.delete()
    e.pick("omw")
    type("omw ", e, start: 20)
    #expect(p.text == "ok omw omw ")
  }

  /// UILexicon entries: shortcuts (any apostrophe, case-only changes too) become replacements; names and
  /// phrases without a shortcut become words never corrected; shortcuts with other marks are left out.
  @Test func theSystemLexiconSplitsIntoReplacementsAndWords() throws {
    let (r, w) = TypingEngine.systemLexicon([("omw", "On my way!"), ("v2t", "V2T"), ("we’re", "we are"),
                                             ("Siobhan", "Siobhan"), (";em", "—"), ("", "Nobody Corrects")])
    #expect(r == ["omw": "On my way!", "v2t": "V2T", "we're": "we are"])
    #expect(w == ["siobhan", "nobody", "corrects"])
    let (e, p) = try engine("ok ")
    e.replacements = r
    type("we", e)
    e.character("’", now: 50)
    type("re ", e, start: 60)
    #expect(p.text == "ok we are ")
  }

  /// Delete reopens a phrase replacement; typing on continues its last word, not a new one.
  @Test func typingOnAfterReopeningAPhraseContinuesItsLastWord() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["lt": "local tax"]
    type("lt ", e)
    e.delete()
    type("i ", e, start: 20)
    #expect(p.text == "ok local taxi ")
  }

  /// Space, return or dictated text after delete reopened a phrase end the offer: the shortcut can no
  /// longer delete text that is not the phrase.
  @Test func movingOnEndsAPhraseRevertOffer() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["aw": "a way"]
    type("aw ", e)
    e.delete()
    type(" ", e, start: 20)
    #expect(e.revertOffer == nil && p.text == "ok a way ")
  }

  /// A one-word replacement reopened by delete is still the user's text: space leaves it as it is.
  @Test func aReopenedOneWordReplacementIsNotAutocorrected() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["qq": "teh"]
    type("qq ", e)
    e.delete()
    type(" ", e, start: 20)
    #expect(p.text == "ok teh ")
  }

  /// Dictated text after a correction is not offered for revert, even when it ends the same way.
  @Test func dictatedTextCannotBeReverted() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["lt": "local tax"]
    type("lt", e)
    e.insertFinished("local tax")
    type(" ", e, start: 20)
    e.delete()
    #expect(e.revertOffer == nil && p.text == "ok local tax local tax")
  }

  /// A never-correct word given with a curly apostrophe protects the straight spelling too.
  @Test func aProtectedWordMatchesEitherApostrophe() throws {
    let (e, p) = try engine("I ")
    e.learned = TypingEngine.systemLexicon([("", "do’nt")]).words
    type("do'nt ", e)
    #expect(p.text == "I do'nt ")
  }

  /// A rejected shortcut stays rejected whichever apostrophe it is typed with.
  @Test func aRejectedShortcutStaysRejectedWithEitherApostrophe() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["we're": "we are"]
    type("we", e)
    e.character("’", now: 50)
    type("re ", e, start: 60)
    e.delete()
    e.pick("we’re")
    type("we're ", e, start: 80)
    #expect(p.text == "ok we’re we're ")
  }

  /// A correction of a word typed with a curly apostrophe keeps it, in the bar and on space alike.
  @Test func aCorrectionKeepsTheTypedCurlyApostrophe() throws {
    let (e, p) = try engine("I ")
    type("do", e)
    e.character("’", now: 50)
    type("nt", e, start: 60)
    let pending = e.pendingAutocorrection
    #expect(pending == "don’t" && e.suggestions().map(\.word).contains("don’t"))
    type(" ", e, start: 70)
    #expect(p.text == "I don’t ")
  }

  /// A real word typed with a curly apostrophe shows once in the bar, not also as its straight spelling.
  @Test func aCurlyWordShowsOnceInTheBar() throws {
    let (e, _) = try engine("I ")
    type("don", e)
    e.character("’", now: 50)
    type("t", e, start: 60)
    let bar = e.suggestions().map(\.word)
    #expect(bar.contains("don’t") && bar.count == Set(bar).count, "\(bar)")
  }

  /// Delete after a correction that kept a curly apostrophe offers it back with the same apostrophe, once.
  @Test func theRevertBarKeepsTheTypedApostrophe() throws {
    let (e, _) = try engine("I ")
    type("do", e)
    e.character("’", now: 50)
    type("nt ", e, start: 60)
    e.delete()
    let bar = e.suggestions().map(\.word)
    #expect(bar.first == "do’nt" && !bar.contains("don't") && bar.count == Set(bar).count, "\(bar)")
  }

  /// A shortcut that is also a URL scheme expands at the colon, and goes back when the address goes on.
  @Test func aSchemeShortcutGoesBackInAnAddress() throws {
    let (e, p) = try engine("see ")
    e.replacements = ["https": "https://example.com"]
    type("https", e)
    e.character(":", now: 50)
    e.character("/", now: 51)
    #expect(p.text == "see https:/")
  }

  /// A capitalised rare word mid-sentence is a name, not cant missing its apostrophe.
  @Test func aCapitalisedRareWordMidSentenceStays() throws {
    let (e, p) = try engine("I know ")
    e.character("C", now: 50)  // type() taps lowercase keys
    type("ant ", e, start: 60)
    #expect(p.text == "I know Cant ")
  }

  /// A curly-apostrophe shortcut shows once beside its phrase.
  @Test func aCurlyShortcutShowsOnceBesideItsPhrase() throws {
    let (e, _) = try engine("I ")
    e.replacements = ["don't": "do not"]
    type("don", e)
    e.character("’", now: 50)
    type("t", e, start: 60)
    let bar = e.suggestions().map(\.word)
    #expect(bar.prefix(2) == ["don’t", "do not"] && bar.count == Set(bar).count, "\(bar)")
  }

  /// An address mark after a corrected word's plus sign ("teh+_tag") puts the word back too.
  @Test func anAddressMarkAfterAPlusUndoesItsCorrection() throws {
    let (e, p) = try engine("mail ")
    type("teh", e)
    e.character("+", now: 50)
    e.character("_", now: 51)
    #expect(p.text == "mail teh+_")
  }

  /// With a curly apostrophe typed, the bar's correction is spelled the same, so tapping it matches space.
  @Test func theBarSpellsApostrophesAsTyped() throws {
    let (e, _) = try engine("and ")
    type("i", e)
    e.character("’", now: 50)
    type("m", e, start: 60)
    #expect(e.pendingAutocorrection == "I’m")
    #expect(e.suggestions().map(\.word).contains("I’m"))
  }

  /// A plus sign after a corrected word, then a letter: an email tag ("teh+tag@"), so the word goes back.
  @Test func aLetterAfterAPlusUndoesItsCorrection() throws {
    let (e, p) = try engine("mail ")
    type("teh", e)
    e.character("+", now: 50)
    #expect(p.text == "mail the+")
    type("tag", e, start: 60)
    e.character("@", now: 70)
    #expect(p.text == "mail teh+tag@")
  }

  /// A full stop straight after a corrected word's plus sign ("teh+.tag@") keeps the whole address as typed.
  @Test func aFullStopAfterAPlusKeepsTheAddress() throws {
    let (e, p) = try engine("mail ")
    type("teh", e)
    for (i, c) in "+.".enumerated() { e.character(String(c), now: Double(50 + i)) }
    type("tag", e, start: 60)
    e.character("@", now: 70)
    type("example", e, start: 80)
    e.character(".", now: 90)
    type("com ", e, start: 100)
    #expect(p.text == "mail teh+.tag@example.com ")
  }

  /// A case-only replacement typed already as written offers nothing and learns nothing.
  @Test func aCaseOnlyReplacementTypedAsWrittenIsANoOp() throws {
    let (e, p) = try engine("ok ")
    e.replacements = ["v2t": "V2T"]
    for (i, c) in "V2T".enumerated() { e.character(String(c), now: Double(10 + i)) }
    #expect(e.pendingAutocorrection == nil)
    let bar = e.suggestions().map(\.word)
    #expect(bar.count == Set(bar).count, "\(bar)")
    type(" ", e, start: 20)
    e.delete()
    #expect(e.revertOffer == nil && p.text == "ok V2T" && !e.learned.contains("v2t"))
  }

  /// An equals sign after a corrected word, then more address: the word goes back ("teh=tag@").
  @Test func anEqualsSignInAnAddressKeepsTheWord() throws {
    let (e, p) = try engine("mail ")
    type("teh", e)
    e.character("=", now: 50)
    type("tag", e, start: 60)
    e.character("@", now: 70)
    type("example", e, start: 80)
    e.character(".", now: 90)
    type("com ", e, start: 100)
    #expect(p.text == "mail teh=tag@example.com ")
  }

  /// The bar's word as typed keeps both apostrophes exactly as typed, and tapping it learns it.
  @Test func theTypedSlotKeepsMixedApostrophes() throws {
    let (e, _) = try engine("I like ")
    type("rock", e)
    e.character("'", now: 50)
    type("n", e, start: 60)
    e.character("’", now: 70)
    type("rol", e, start: 80)
    #expect(e.suggestions().first?.word == "rock'n’rol")
    e.pick("rock'n’rol")
    #expect(e.learned.contains("rock'n'rol"))
  }

  /// Tapping "i'm" as typed over its "I'm" correction keeps it lowercase and learns it.
  @Test func tappingLowercaseIMKeepsIt() throws {
    let (e, p) = try engine("and ")
    type("i", e)
    e.character("'", now: 50)
    type("m", e, start: 60)
    #expect(e.pendingAutocorrection == "I'm" && e.suggestions().first?.word == "i'm")
    e.pick("i'm")
    #expect(p.text == "and i'm " && e.learned.contains("i'm"))
  }

  /// "i’m" takes the capital and keeps the curly apostrophe typed.
  @Test func iContractionsKeepTheirApostrophe() throws {
    let (e, p) = try engine("and ")
    type("i", e)
    e.character("’", now: 50)
    type("m ", e, start: 60)
    #expect(p.text == "and I’m ")
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
