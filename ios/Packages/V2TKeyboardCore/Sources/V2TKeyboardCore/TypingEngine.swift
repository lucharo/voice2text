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
  public private(set) var composing: [TypedKey] = []
  /// Words the user insisted on (reverted an autocorrect, or picked as typed); never autocorrected.
  public var learned: Set<String> = []
  public var onLearn: ((String) -> Void)?
  /// Text replacements (lowercase shortcut -> phrase), as Settings > General > Keyboard > Text Replacement.
  public var replacements: [String: String] = [:]

  /// The last autocorrect, while the text still ends with it, so a delete can offer the original back.
  public private(set) var lastCorrection: (original: String, replacement: String)?
  /// Set after a delete removed the space after an autocorrect: the bar offers `original` to revert to.
  public private(set) var revertOffer: String?
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
    if ch.isLetter || ch.isNumber || Self.isApostrophe(ch) && !composing.isEmpty {
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
    commitWord()
    if attaches, autoSpace, before.hasSuffix(" ") {
      proxy.deleteBackward()
      proxy.insertText(s + " ")
      autoSpace = true
    } else {
      proxy.insertText(s)
      autoSpace = false
    }
    lastSwipe = nil
    lastCorrection = nil
    revertOffer = nil
    refreshShift()
  }

  public func space(now: TimeInterval = 0) {
    defer { lastSpaceAt = now }
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
    if autoSpace { autoSpace = false; refreshShift(); return }  // the space is already there
    commitWord()
    proxy.insertText(" ")
    refreshShift()
  }

  public func returnKey() {
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
      composing = c.replacement.map { TypedKey($0) }
      revertOffer = c.original
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
      return [Suggestion(word: r, kind: .typed, score: 0)] + suggester.suggestions(for: composing, context: context, limit: 2).filter { $0.word != r }
    }
    if let s = lastSwipe {
      return Self.bestInMiddle(s.alternatives.prefix(3).map { Suggestion(word: $0, kind: .correction, score: 0) })
    }
    guard !composing.isEmpty else {
      // nothing typed yet: predict the next word, capitalised where the sentence or field wants it
      guard before.last.map(Self.isGap) ?? true else { return [] }
      return Self.bestInMiddle(suggester.predictions(context: context).map { Suggestion(word: styled($0.word), kind: $0.kind, score: $0.score) })
    }
    let all = suggester.suggestions(for: composing, context: context, limit: 3)
    let typed = all.filter { $0.kind == .typed }, rest = all.filter { $0.kind != .typed }
    return typed + rest
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

  /// The user tapped a suggestion: it replaces the word, followed by a space.
  public func pick(_ word: String) {
    let replacing: Int
    if let s = lastSwipe { replacing = s.word.count } else { replacing = composing.count }
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
    commitWord()
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
    var word: [TypedKey] = []
    for ch in before.reversed() {
      guard ch.isLetter || ch.isNumber || Self.isApostrophe(ch) else { break }  // as character() composes
      word.insert(TypedKey(ch), at: 0)
    }
    composing = word
    refreshShift()
  }

  // MARK: internals

  /// The word a space would put in place of the one being typed, or nil when it would stay as typed: the
  /// field's autocorrect setting and the learned words apply, as in commitWord. The bar bolds this word.
  public var pendingAutocorrection: String? {
    guard !composing.isEmpty, traits.autocorrect,
          let fix = suggester.autocorrection(for: composing, learned: learned, context: context), fix != literal else { return nil }
    return fix
  }

  /// Autocorrects the word under construction, if it needs it.
  func commitWord() {
    defer { composing = [] }
    guard let fix = pendingAutocorrection else { return }
    let original = literal
    for _ in 0..<composing.count { proxy.deleteBackward() }
    proxy.insertText(fix)
    lastCorrection = (original, fix)
  }

  func spaceIfNeeded() {
    guard let last = before.last else { return }
    if !(Self.isGap(last) || "([{¿¡“«\"'".contains(last)) { proxy.insertText(" ") }
  }

  /// What separates words: space, newline, and the 13-inch iPad keyboard's tab.
  static func isGap(_ c: Character) -> Bool { c == " " || c == "\n" || c == "\t" }

  /// Inside a word ("don't", "Teh’Code"): the straight apostrophe and the curly one from its long press.
  static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "’" }

  func learn(_ word: String) {
    let w = word.lowercased()
    guard learned.insert(w).inserted else { return }
    onLearn?(w)
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
