import CoreGraphics
import Foundation

/// The parts of UITextDocumentProxy the engine uses, so it runs and is tested without UIKit.
public protocol TextProxy: AnyObject {
  var documentContextBeforeInput: String? { get }
  func insertText(_ text: String)
  func deleteBackward()
}

public enum ShiftState: Sendable, Equatable { case off, on, locked }

/// What the host field asks for (from UITextInputTraits).
public struct FieldTraits: Sendable, Equatable {
  public enum Capitalization: Sendable { case none, words, sentences, all }
  public var capitalization: Capitalization = .sentences
  public var autocorrect = true
  public init(capitalization: Capitalization = .sentences, autocorrect: Bool = true) {
    self.capitalization = capitalization
    self.autocorrect = autocorrect
  }
}

/// Turns key presses into text edits the way Apple's keyboard does: shift and caps lock, sentence
/// capitals, autocorrect when a word ends with tap-to-revert, a double-tapped space as ". ", a space after a
/// chosen suggestion or swiped word that punctuation pulls back, and word-at-a-time delete.
public final class TypingEngine {
  public let proxy: TextProxy
  public var suggester: Suggester
  public var traits = FieldTraits()
  public private(set) var shift: ShiftState = .off { didSet { shiftManual = false } }
  /// Shift is on because the user tapped it, not because a sentence or field starts: only then do the full
  /// iPad keyboard's number and punctuation keys type their second mark.
  public private(set) var shiftManual = false
  /// Keys of the word under construction, since the last word boundary.
  public private(set) var composing: [TypedKey] = [] { didSet { if composing.isEmpty { composingResynced = false } } }
  /// The word under construction began as text already in the document (read back by `resync`), not as keys
  /// typed here: the debug log keeps its letters out, since they may be dictated ones (#162).
  public private(set) var composingResynced = false
  /// Words the user insisted on (reverted an autocorrect, or picked as typed); never autocorrected.
  public var learned: Set<String> = [] {
    // kept lowercase with straight apostrophes, as `learn` stores them, so either apostrophe matches
    didSet { if learned.contains(where: { $0.contains("’") || $0 != $0.lowercased() }) { learned = Set(learned.map(Self.shortcutKey)) } }
  }
  public var onLearn: ((String) -> Void)?
  /// A word the user kept that no word list knows ("marimo" over the correction "merino"), spelt as typed,
  /// for the keyboard to add to the v2t dictionary as a term.
  public var onNewWord: ((String) -> Void)?
  /// Text replacements (lowercase shortcut -> phrase), as Settings > General > Keyboard > Text Replacement.
  public var replacements: [String: String] = [:]
  /// The emoji keywords by language ("en", "es"); the bar offers the emoji a word names, as Apple's does for
  /// "pizza" or "love". Empty leaves the bar words only.
  public var emojiIndexes: [String: EmojiIndex] = [:]
  /// The emoji as the user last picked it (the keywords list base forms): the bar offers 👍🏽 for "thumbs"
  /// once 👍🏽 was picked, or is the default tone. Nil offers the base form.
  public var emojiShown: ((String) -> String)?
  /// What the engine decided, for the keyboard's debug log (#162): nil when nobody listens.
  public var onEvent: ((Event) -> Void)?

  /// Decisions the debug log records: what autocorrect changed, what the user took back, what a tap on the bar
  /// replaced, what a swipe typed.
  public enum Event: Equatable, Sendable {
    /// A word ended and autocorrect put `replacement` in place of `original`.
    case autocorrected(original: String, replacement: String)
    /// Delete after a correction removed its space: the bar now offers `original` back.
    case revertOffered(original: String, replacement: String)
    /// The correction was undone: `how` is "bar" (the original picked from the bar) or "address" (the word
    /// turned out to be part of a web or email address).
    case reverted(original: String, replacement: String, how: String)
    /// A suggestion tapped in the bar replaced `replaced` (the word as typed, or the swiped word).
    case picked(word: String, replaced: String)
    /// A swipe typed `word`, with `alternatives` waiting in the bar.
    case swiped(word: String, alternatives: [String])

    /// The event's name, without its words.
    public var name: String {
      switch self {
      case .autocorrected: "autocorrect"
      case .revertOffered: "revert-offer"
      case .reverted: "revert"
      case .picked: "picked"
      case .swiped: "swiped"
      }
    }
  }

  /// The last autocorrect, while the text still ends with it, so a delete can offer the original back.
  public private(set) var lastCorrection: (original: String, replacement: String)? {
    didSet { if lastCorrection == nil { correctionThenMark = nil; correctionReadBack = false } }
  }
  /// The last correction was made to a word read back from the document, not typed here.
  private var correctionReadBack = false
  /// The engine holds text it read back from the document rather than keys typed here: the word being typed, or
  /// a correction of such a word (still offered back after a delete). The debug log keeps it out (#162).
  public var holdsReadBackText: Bool { composingResynced || (lastCorrection != nil && correctionReadBack) }
  /// The address marks typed straight after an autocorrect ("." or "+", "+!" as more follow): a letter or an
  /// address mark next means the word was part of an address ("exmaple.com", "teh+!tag@", "https://"), so it
  /// is undone; a space keeps it ("teh?! ").
  private var correctionThenMark: String?
  /// Set after a delete removed the space after an autocorrect: the bar offers `original` to revert to.
  public private(set) var revertOffer: String? { didSet { if revertOffer == nil { revertPhrase = nil } } }
  /// While `revertOffer` stands for a phrase (a text replacement: "On my way!"), the phrase picking the
  /// original deletes; the phrase is not a word to keep typing, so it is not put back into `composing`.
  private var revertPhrase: String?
  /// We put a space after a suggestion, swipe or correction; punctuation typed next pulls it back.
  private var autoSpace = false
  private var lastSwipe: (word: String, alternatives: [String])?
  private var lastSpaceAt: TimeInterval = -1
  private var lastShiftAt: TimeInterval = -1
  static let doubleTap: TimeInterval = 0.35

  public init(proxy: TextProxy, suggester: Suggester) {
    self.proxy = proxy
    self.suggester = suggester
    refreshShift()
  }

  var before: String { proxy.documentContextBeforeInput ?? "" }
  var literal: String { String(composing.map(\.character)) }

  // MARK: keys

  public func character(_ s: String, at point: CGPoint? = nil, now: TimeInterval = 0) {
    guard let ch = s.first else { return }
    // typing on after delete reopened a phrase replacement ("local tax"): the word is its last one, so an
    // apostrophe joins it ("we're") rather than starting a word of its own
    if revertPhrase != nil, ch.isLetter || ch.isNumber || Self.isApostrophe(ch) {
      composing = Self.trailingWord(before)
      // the phrase was a correction of text read back from the document ("needsme" -> "needs me"): its last word,
      // typed on, still is, for the debug log (#162)
      composingResynced = !composing.isEmpty && correctionReadBack
      revertOffer = nil
    }
    if ch.isLetter || ch.isNumber || Self.isApostrophe(ch) && !composing.isEmpty {
      // "exmaple." then "c": an address, not a sentence end; put the word back as typed
      undoCorrectionBeforeMark()
      if lastSwipe != nil { spaceIfNeeded() }  // a letter after a swiped word starts the next word
      lastSwipe = nil
      autoSpace = false
      lastCorrection = nil
      revertOffer = nil
      let text = shift == .off ? s : s.uppercased()  // "ß" uppercases to two letters, "SS"
      proxy.insertText(text)
      composing += text.map { TypedKey($0, at: point) }
      if shift == .on { shift = .off }
      if traits.capitalization == .all { shift = .on }
    } else {
      punctuation(s)
    }
  }

  func punctuation(_ s: String) {
    let closesSentence = [".", "!", "?"].contains(s)
    let attaches = closesSentence || [",", ";", ":", ")", "”", "»", "…"].contains(s)
    // "teh+_tag": an address mark after the plus, so the word goes back as typed
    // a full stop after a corrected word's plus sign ("teh+.tag") is inside an email tag too; after full
    // stops only ("teh..."), it is an ellipsis still waiting for what follows
    if "@_+/:#\\=".contains(s) || s == "." && correctionThenMark?.contains(where: { $0 != "." }) == true { undoCorrectionBeforeMark() }
    // before "@" or "_" the word is an email address or a handle ("jhon@", "jhon_doe"): left as typed
    let corrected = ["@", "_"].contains(s) ? { composing = []; return false }() : commitWord()
    if attaches, autoSpace, before.hasSuffix(" ") {
      proxy.deleteBackward()
      proxy.insertText(s + " ")
      autoSpace = true
    } else {
      proxy.insertText(s)
      autoSpace = false
    }
    lastSwipe = nil
    // marks an email address can hold straight after a word ("teh!tag@", "teh#tag@"): a letter next undoes it.
    // They add up until something else decides: "teh+!tag@" is an address, "teh?! " a sentence (#136)
    let mark = Self.addressMarks.contains(s)
    if corrected { correctionThenMark = mark ? s : nil } else if mark, let m = correctionThenMark { correctionThenMark = m + s } else { correctionThenMark = nil }
    if correctionThenMark == nil { lastCorrection = nil }
    revertOffer = nil
    refreshShift()
  }

  public func space(now: TimeInterval = 0) {
    defer { lastSpaceAt = now }
    revertOffer = nil
    if composing.isEmpty, now - lastSpaceAt < Self.doubleTap, before.hasSuffix(" "),
       let prev = before.dropLast().last, prev.isLetter || prev.isNumber {
      proxy.deleteBackward()
      proxy.insertText(". ")
      autoSpace = false
      lastCorrection = nil
      lastSpaceAt = -1
      refreshShift()
      return
    }
    lastSwipe = nil
    correctionThenMark = nil  // a space after "the?!" ends the sentence: the correction stays
    if autoSpace { autoSpace = false; refreshShift(); return }  // the space is already there
    commitWord()
    proxy.insertText(" ")
    refreshShift()
  }

  public func returnKey() {
    revertOffer = nil
    commitWord()
    proxy.insertText("\n")
    autoSpace = false
    lastSwipe = nil
    lastCorrection = nil
    refreshShift()
  }

  public func delete() {
    revertOffer = nil
    if let c = lastCorrection, before.hasSuffix(c.replacement + " ") {
      proxy.deleteBackward()
      revertOffer = c.original
      onEvent?(.revertOffered(original: c.original, replacement: c.replacement))
      // a text replacement is the user's own text: reopened, it is not a word to autocorrect again
      let replaced = replacements[Self.shortcutKey(c.original)] == c.replacement
      if !replaced, c.replacement.allSatisfy({ $0.isLetter || Self.isApostrophe($0) }) {
        composing = c.replacement.map { TypedKey($0) }
        composingResynced = correctionReadBack  // the reopened word is still the one read back
      } else {
        revertPhrase = c.replacement
      }
      autoSpace = false
      refreshShift()
      return
    }
    lastCorrection = nil
    autoSpace = false
    lastSwipe = nil
    proxy.deleteBackward()
    if !composing.isEmpty { composing.removeLast() } else { resync() }
    refreshShift()
  }

  /// Delete held long enough to go a word at a time: the word before the cursor and the spaces after it.
  public func deleteWord() {
    lastCorrection = nil
    revertOffer = nil
    autoSpace = false
    lastSwipe = nil
    var text = before
    var n = 0
    while let last = text.last, Self.isGap(last) { text.removeLast(); n += 1 }
    while let last = text.last, !Self.isGap(last) { text.removeLast(); n += 1 }
    if n == 0 { return }
    for _ in 0..<n { proxy.deleteBackward() }
    composing = []
    refreshShift()
  }

  public func shiftTap(now: TimeInterval = 0) {
    switch shift {
    case .off: shift = now - lastShiftAt < Self.doubleTap ? .locked : .on
    case .on: shift = now - lastShiftAt < Self.doubleTap ? .locked : .off
    case .locked: shift = .off
    }
    shiftManual = shift == .on
    lastShiftAt = now
  }

  /// The full iPad keyboard's caps lock key: locks in one tap, unlocks in the next.
  public func capsLockTap() {
    shift = shift == .locked ? .off : .locked
  }

  // MARK: suggestions and swipes

  /// Three slots, as Apple's bar: the word as typed (or the original to revert to), the best suggestion,
  /// the next one.
  public func suggestions() -> [Suggestion] {
    if let r = revertOffer {
      return [Suggestion(word: r, kind: .typed, score: 0)] + typedApostrophes(suggester.suggestions(for: composing, context: context, limit: 3)).filter { $0.word != r }.prefix(2)
    }
    if let s = lastSwipe {
      return Self.bestInMiddle(s.alternatives.prefix(3).map { Suggestion(word: $0, kind: .correction, score: 0) })
    }
    guard !composing.isEmpty else {
      // nothing typed yet: predict the next word, capitalised where the sentence or field wants it
      guard before.last.map(Self.isGap) ?? true else { return [] }
      return Self.bestInMiddle(suggester.predictions(context: context).map { Suggestion(word: styled($0.word), kind: $0.kind, score: $0.score) })
    }
    let all = typedApostrophes(suggester.suggestions(for: composing, context: context, limit: 3))
    // the word as typed once ("don’t" typed and the list's "don't" read the same once spelled alike)
    let typed = all.filter { $0.kind == .typed }, rest = all.filter { $0.kind != .typed && !typed.map(\.word).contains($0.word) }
    if let r = pendingReplacement {
      // a text replacement takes the middle slot, beside the shortcut as typed
      return [Suggestion(word: literal, kind: .typed, score: 0), Suggestion(word: r, kind: .correction, score: 0)] + rest.filter { $0.word != r && $0.word != literal }.prefix(1)
    }
    var slots = typed + rest
    // the word a space would put in is always in the bar, in the middle: commoner completions can fill the
    // three slots ("som": some, someone) while autocorrect applies a correction none of them shows ("son")
    if let fix = pendingAutocorrection, slots.count < 2 || slots[1].word != fix {
      slots.removeAll { $0.word == fix }
      slots.insert(Suggestion(word: fix, kind: .correction, score: 0), at: min(1, slots.count))
    }
    guard let e = emojiSuggestion else { return Array(slots.prefix(3)) }
    // the emoji takes the last slot, as on Apple's bar
    return Array(slots.prefix(2)) + [Suggestion(word: e, kind: .emoji, score: 0)]
  }

  /// The emoji the bar offers for the word being typed (or the word autocorrect would make of it), when it
  /// is at least three letters long and names one, in the language being written: English "pie" is 🥧,
  /// Spanish "pie" a foot. Only the suggestion languages' keywords count.
  public var emojiSuggestion: String? {
    guard !emojiIndexes.isEmpty, !composing.isEmpty, revertOffer == nil else { return nil }
    let languages = suggester.lexicons.map(\.language)
    let first = [suggester.languagePrior.recentLanguage, suggester.layout.language.rawValue].compactMap { $0 }
    var order: [String] = []
    for l in first + languages where languages.contains(l) && !order.contains(l) { order.append(l) }
    func emoji(_ word: String) -> String? {
      guard word.count >= 3 else { return nil }
      for l in order { if let e = emojiIndexes[l]?.emoji(for: word).first { return e } }
      return nil
    }
    // the word as typed first: the correction is a beam search, only run when the word itself names nothing
    let found = emoji(literal) ?? pendingAutocorrection.flatMap(emoji)
    return found.map { emojiShown?($0) ?? $0 }
  }

  /// Suggestions spelled with the apostrophe the user typed ("i’m": I’m), so a tap writes what space would,
  /// and without the repeats that spelling makes ("don’t" and the list's "don't").
  func typedApostrophes(_ list: [Suggestion]) -> [Suggestion] {
    guard composing.contains(where: { $0.character == "’" }) else { return list }
    // the word as typed stays exactly as typed ("rock'n’roll"), and goes first so a repeat of it is dropped
    var seen = Set(list.filter { $0.kind == .typed }.map(\.word))
    return list.filter { $0.kind == .typed } + list.filter { $0.kind != .typed }
      .map { Suggestion(word: $0.word.replacingOccurrences(of: "'", with: "’"), kind: $0.kind, score: $0.score) }
      .filter { seen.insert($0.word).inserted }
  }

  /// A whole word as the shift state writes it: caps lock and all-capitals fields write it in capitals, a
  /// single shift only its first letter.
  func styled(_ word: String) -> String {
    if shift == .locked || traits.capitalization == .all { return word.uppercased() }
    return shift != .off ? word.prefix(1).uppercased() + word.dropFirst() : word
  }

  /// The bar's middle slot is the bold, best one: [second, best, third].
  static func bestInMiddle(_ s: [Suggestion]) -> [Suggestion] {
    s.count >= 2 ? [s[1], s[0]] + s.dropFirst(2) : s
  }

  /// The words before the one being typed.
  public var context: TypingContext { TypingContext(before: String(before.dropLast(composing.count))) }

  /// The user tapped a suggestion: it replaces the word, followed by a space. The bar's emoji replaces the
  /// word the same way, as Apple's does.
  public func pick(_ word: String) {
    let replacing: Int
    if let s = lastSwipe { replacing = s.word.count } else if revertOffer == word, let ph = revertPhrase, before.hasSuffix(ph) { replacing = ph.count } else { replacing = composing.count }
    if let onEvent {
      if revertOffer == word, let c = lastCorrection { onEvent(.reverted(original: c.original, replacement: c.replacement, how: "bar")) }
      else { onEvent(.picked(word: word, replaced: lastSwipe?.word ?? literal)) }
    }
    for _ in 0..<replacing { proxy.deleteBackward() }
    if revertOffer == word || word == literal { learn(word) }
    proxy.insertText(word + " ")
    composing = []
    revertOffer = nil
    lastCorrection = nil
    lastSwipe = nil
    autoSpace = true
    refreshShift()
  }

  /// A swipe decoded to `candidates` (best first): the best is inserted as a word of its own, and the others
  /// wait in the bar.
  public func swipe(_ candidates: [String]) {
    guard !candidates.isEmpty else { return }
    commitWord()
    spaceIfNeeded()
    let words = candidates.map(styled)
    let word = words[0]
    if shift == .on { shift = .off }
    if traits.capitalization == .all { shift = .on }
    proxy.insertText(word)
    autoSpace = false
    lastCorrection = nil
    revertOffer = nil
    lastSwipe = (word, Array(words.dropFirst()))
    onEvent?(.swiped(word: word, alternatives: Array(words.dropFirst())))
    composing = []
    noteLanguage()
  }

  /// An emoji from the emoji panel. It ends the word in progress as typed, without autocorrecting it (the user
  /// left the letters to pick a picture, not to accept a correction), and needs no space before or after it.
  public func emoji(_ s: String) {
    proxy.insertText(s)
    composing = []
    lastSwipe = nil
    autoSpace = false
    lastCorrection = nil
    revertOffer = nil
    refreshShift()
  }

  /// Text was inserted through the dictation route (or pasted): it reads as words already finished.
  public func insertFinished(_ text: String) {
    revertOffer = nil
    commitWord()
    lastCorrection = nil  // the text after it is not ours to revert
    spaceIfNeeded()
    proxy.insertText(text)
    composing = []
    lastSwipe = nil
    autoSpace = false
    refreshShift()
  }

  /// The keyboard's geometry changed (rotation, resize, layout language): score with `suggester` from now on,
  /// and forget where the keys of the word in progress were touched, since those points belong to the old
  /// layout. The word itself, shift and the pending autocorrect state stay. A page switch that comes back to
  /// the same letter geometry (numbers for an apostrophe, then letters) keeps the points.
  public func replaceLayout(with suggester: Suggester) {
    let moved = suggester.layout.letterCenters != self.suggester.layout.letterCenters || suggester.layout.unitWidth != self.suggester.layout.unitWidth
    suggester.languagePrior.recentLanguage = self.suggester.languagePrior.recentLanguage
    self.suggester = suggester
    if moved { composing = composing.map { TypedKey($0.character) } }
  }

  /// The host moved the cursor or changed the text itself: forget our state and read the word at the cursor.
  public func resync() {
    composing = []
    lastSwipe = nil
    autoSpace = false
    lastCorrection = nil
    revertOffer = nil
    composing = Self.trailingWord(before)
    composingResynced = !composing.isEmpty
    refreshShift()
  }

  /// The word at the end of `text`, as character() composes it.
  static func trailingWord(_ text: String) -> [TypedKey] {
    var word: [TypedKey] = []
    for ch in text.reversed() {
      guard ch.isLetter || ch.isNumber || isApostrophe(ch) else { break }
      word.insert(TypedKey(ch), at: 0)
    }
    return word
  }

  /// Marks that can sit inside a web or email address right after a word (RFC 5322's local part, ":" of a
  /// scheme): a correction made at one is undone if the address goes on.
  static let addressMarks: Set<String> = [".", "+", ":", "=", "!", "#", "$", "%", "&", "*", "?", "^", "{", "|", "}", "~"]

  /// A correction followed by an address mark turned out to be inside an address: put the word back as typed.
  func undoCorrectionBeforeMark() {
    defer { correctionThenMark = nil }
    guard let m = correctionThenMark, let c = lastCorrection, before.hasSuffix(c.replacement + m) else { return }
    onEvent?(.reverted(original: c.original, replacement: c.replacement, how: "address"))
    for _ in 0..<(c.replacement.count + m.count) { proxy.deleteBackward() }
    proxy.insertText(c.original + m)
  }

  // MARK: internals

  /// The word a space would put in place of the one being typed, or nil when it would stay as typed: the
  /// field's autocorrect setting and the learned words apply, as in commitWord. The bar bolds this word.
  public var pendingAutocorrection: String? {
    guard !composing.isEmpty, traits.autocorrect, !inAddress else { return nil }
    if let r = pendingReplacement { return r }
    guard var fix = suggester.autocorrection(for: composing, learned: learned, context: context), fix != literal else { return nil }
    // the apostrophe the user typed, as the bar shows it ("do’nt": don’t)
    if composing.contains(where: { $0.character == "’" }) { fix = fix.replacingOccurrences(of: "'", with: "’") }
    return fix
  }

  /// The user's text replacement for the word being typed, if it is a shortcut the user has not rejected.
  var pendingReplacement: String? {
    let key = Self.shortcutKey(literal)
    guard !composing.isEmpty, traits.autocorrect, !inAddress, !learned.contains(key), !learned.contains(literal.lowercased()) else { return nil }
    // a case-only replacement already typed as written ("V2T" for v2t -> V2T) has nothing to do
    guard let r = replacements[key], r != literal else { return nil }
    return r
  }

  /// How a shortcut is looked up: lowercase, straight apostrophes.
  static func shortcutKey(_ s: String) -> String { Suggester.straightApostrophes(s.lowercased()) }

  /// The system's supplementary lexicon (UILexicon: the user's text replacements, contact names, phrases
  /// with no shortcut) as replacements keyed by `shortcutKey`, and the words never to correct (lowercase).
  /// A shortcut the engine cannot see as one word (";em", "@@") is left out.
  public static func systemLexicon(_ entries: [(input: String, text: String)]) -> (replacements: [String: String], words: Set<String>) {
    var replacements: [String: String] = [:], words = Set<String>()
    for (input, text) in entries {
      let word = !input.isEmpty && input.allSatisfy { $0.isLetter || $0.isNumber || isApostrophe($0) }
      if word, input != text {
        replacements[shortcutKey(input)] = text  // "v2t" -> "V2T" too: a change of case is a replacement
      } else {
        words.formUnion(text.split { !($0.isLetter || $0.isNumber || isApostrophe($0)) }.map { shortcutKey(String($0)) })
      }
    }
    return (replacements, words)
  }

  /// The word being typed is part of a web or email address, an @handle or a #hashtag: what is joined to it
  /// before it ("www.", "jhon@", "@", "#", "http://") holds one of these marks.
  var inAddress: Bool {
    var i = before.index(before.endIndex, offsetBy: -composing.count, limitedBy: before.startIndex) ?? before.startIndex
    while i > before.startIndex {
      i = before.index(before: i)
      let c = before[i]
      if Self.isGap(c) { return false }
      if "@#/.:_\\".contains(c) { return true }
    }
    return false
  }

  /// Autocorrects the word under construction, if it needs it; true when it changed it.
  @discardableResult func commitWord() -> Bool {
    defer { composing = [] }
    guard let fix = pendingAutocorrection else { return false }
    let original = literal
    for _ in 0..<composing.count { proxy.deleteBackward() }
    proxy.insertText(fix)
    lastCorrection = (original, fix)
    correctionReadBack = composingResynced
    onEvent?(.autocorrected(original: original, replacement: fix))
    return true
  }

  func spaceIfNeeded() {
    guard let last = before.last else { return }
    if !(Self.isGap(last) || "([{¿¡“«\"'".contains(last)) { proxy.insertText(" ") }
  }

  /// What separates words: space, newline, and the 13-inch iPad keyboard's tab.
  static func isGap(_ c: Character) -> Bool { c == " " || c == "\n" || c == "\t" }

  /// Inside a word ("don't", "Teh’Code"): the straight apostrophe and the curly one from its long press.
  static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "’" }

  /// Learned words are kept lowercase with straight apostrophes, so "we’re" and "we're" are one word.
  func learn(_ word: String) {
    let w = Self.shortcutKey(word)
    guard learned.insert(w).inserted else { return }
    onLearn?(w)
    // a new word, not a real one kept as typed ("form") or a text-replacement shortcut kept unexpanded ("omw")
    if word.filter(\.isLetter).count >= 2, replacements[w] == nil, !suggester.isWord(word) { onNewWord?(word) }
  }

  /// Remembers which language the words before the cursor are in, so the next field's first word (which has
  /// no words before it) starts in that language.
  func noteLanguage() {
    if let lang = suggester.languagePrior.likeliest(suggester.lexicons, primary: suggester.layout.language.rawValue, context: context) {
      suggester.languagePrior.recentLanguage = lang
    }
  }

  /// Sentence capitals: at the start of the field, after a newline, or after ". ", "! ", "? ". Also notes the
  /// language written in, since this runs after every word boundary.
  func refreshShift() {
    noteLanguage()
    guard shift != .locked else { return }
    switch traits.capitalization {
    case .none: shift = .off
    case .all: shift = .on
    case .words:
      shift = before.last.map(Self.isGap) ?? true ? .on : .off
    case .sentences:
      let trimmed = before.reversed().drop { $0 == " " }
      let hadSpace = trimmed.count < before.count
      if before.isEmpty || before.last == "\n" { shift = .on }
      else if hadSpace, let p = trimmed.first, ".!?".contains(p) { shift = .on }
      else { shift = .off }
    }
  }
}
