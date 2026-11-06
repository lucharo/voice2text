import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// The emoji key in the bottom row, the emoji panel's data and history, and typing an emoji.
struct EmojiTests {
  static let dataFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../Keyboard/emoji.txt").standardized

  func bottomRow(_ l: KeyboardLayout) -> [String] {
    l.keys.filter { $0.row == l.metrics.rows - 1 }.sorted { $0.frame.minX < $1.frame.minX }.map(\.id)
  }

  // MARK: the key

  @Test func faceIDIPhonesGetTheEmojiKeyInTheGlobesSlot() {
    for page in [KeyboardPage.letters, .numbers, .symbols] {
      #expect(bottomRow(KeyboardLayout(width: 402, page: page, nextKeyboardKey: false)) == ["page", "emoji", "space", "mic", "return"])
    }
    let emoji = KeyboardLayout(width: 402, nextKeyboardKey: false).keys.first { $0.id == "emoji" }!
    #expect(emoji.action == .emoji)
  }

  @Test func whenIOSAsksForAGlobeItComesBeforeTheEmojiKey() {
    #expect(bottomRow(KeyboardLayout(width: 375, nextKeyboardKey: true)) == ["page", "globe", "emoji", "space", "mic", "return"])
    #expect(bottomRow(KeyboardLayout(width: 834, form: .pad, nextKeyboardKey: true)) == ["globe", "emoji", "page", "mic", "space", "page-right", "dismiss"])
    #expect(bottomRow(KeyboardLayout(width: 1024, form: .padFull, nextKeyboardKey: true)) == ["globe", "emoji", "page", "mic", "space", "page-right", "dismiss"])
    #expect(bottomRow(KeyboardLayout(width: 834, form: .pad, nextKeyboardKey: false)) == ["emoji", "page", "mic", "space", "page-right", "dismiss"])
    let globe = KeyboardLayout(width: 375, nextKeyboardKey: true).keys.first { $0.id == "globe" }!
    #expect(globe.action == .nextKeyboard)
  }

  @Test func bothBottomRowsFitWithoutOverlapAndKeepAUsableSpaceBar() {
    var layouts: [KeyboardLayout] = []
    for globe in [true, false] {
      for w: CGFloat in [320, 375, 402, 440] { layouts.append(KeyboardLayout(width: w, nextKeyboardKey: globe)) }
      layouts.append(KeyboardLayout(width: 744, form: .pad, nextKeyboardKey: globe))
      layouts.append(KeyboardLayout(width: 1032, form: .padFull, nextKeyboardKey: globe))
    }
    for l in layouts {
      let row = l.keys.filter { $0.row == l.metrics.rows - 1 }.sorted { $0.frame.minX < $1.frame.minX }
      for (a, b) in zip(row, row.dropFirst()) { #expect(b.frame.minX - a.frame.maxX >= l.metrics.gap - 0.5, "\(l.width) \(a.id) | \(b.id)") }
      #expect(row.last!.frame.maxX <= l.width - l.metrics.sideInset + 0.5, "\(l.width)")
      let space = row.first { $0.id == "space" }!
      #expect(space.frame.width >= 3.5 * l.unitWidth, "\(l.width) globe \(l.nextKeyboardKey): space \(space.frame.width)")
    }
  }

  // MARK: data

  @Test func parsesCategoriesEmojiAndSkinTones() {
    let text = """
      # comment
      @smileys
      😀
      👋,👋🏻,👋🏼,👋🏽,👋🏾,👋🏿
      @flags
      🇬🇧

      """
    #expect(EmojiData.parse(text) == [
      EmojiCategory(id: "smileys", emoji: [Emoji(base: "😀"), Emoji(base: "👋", skinTones: ["👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"])]),
      EmojiCategory(id: "flags", emoji: [Emoji(base: "🇬🇧")]),
    ])
  }

  @Test func theBundledDataHasApplesCategoriesAndWholeSkinToneFamilies() throws {
    let cats = EmojiData.parse(try String(contentsOf: Self.dataFile, encoding: .utf8))
    #expect(cats.map(\.id) == ["smileys", "animals", "food", "activity", "travel", "objects", "symbols", "flags"])
    let all = cats.flatMap(\.emoji)
    #expect(all.count == 1906)  // Unicode Emoji 16.0's fully-qualified emoji, less components and skin-tone variants
    #expect(all.filter { !$0.skinTones.isEmpty }.count == 323)
    #expect(Set(all.map(\.base)).count == all.count)
    #expect(cats[0].emoji.first == Emoji(base: "😀"))
    #expect(all.contains(Emoji(base: "👍", skinTones: ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])))
    #expect(all.contains(Emoji(base: "☝️", skinTones: ["☝🏻", "☝🏼", "☝🏽", "☝🏾", "☝🏿"])))
    for e in all where !e.skinTones.isEmpty {
      #expect(e.skinTones.count == 5 && e.skinTones.allSatisfy { Emoji.family($0) == Emoji.family(e.base) }, "\(e.base)")
    }
    #expect(!all.contains { $0.base == "🏻" })  // the bare skin-tone swatches are components, not emoji to type
    #expect(cats.last!.emoji.contains(Emoji(base: "🇬🇧")))
  }

  // MARK: history

  @Test func usingAnEmojiPutsItFirstAndOnlyOnce() {
    var h = EmojiHistory()
    h.use("😀", from: Emoji(base: "😀"))
    h.use("🎉", from: Emoji(base: "🎉"))
    h.use("😀", from: Emoji(base: "😀"))
    #expect(h.recents == ["😀", "🎉"])
  }

  @Test func recentsKeepTheLastThirty() {
    var h = EmojiHistory()
    let flags = (0..<31).map { i in String(UnicodeScalar(0x1F600 + i)!) }
    for f in flags { h.use(f, from: nil) }
    #expect(h.recents == Array(flags.reversed().prefix(30)))
  }

  @Test func aSkinToneReplacesTheOtherTonesOfTheSameEmojiAndIsShownFromThenOn() {
    let thumbs = Emoji(base: "👍", skinTones: ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
    var h = EmojiHistory()
    h.use("👍", from: thumbs)
    h.use("🎉", from: nil)
    h.use("👍🏽", from: thumbs)
    #expect(h.recents == ["👍🏽", "🎉"])
    #expect(h.tones == ["👍": "👍🏽"])
    #expect(h.shown(thumbs) == "👍🏽")
    h.use("👍", from: thumbs)  // back to the yellow one
    #expect(h.tones == [:])
    #expect(h.shown(thumbs) == "👍")
  }

  @Test func storedHistoryIsCleanedOnLoad() {
    let h = EmojiHistory(recents: ["👍🏽", "👍", "😀"] + Array(repeating: "x", count: 40), tones: ["👍": "👍🏽"])
    #expect(h.recents == ["👍🏽", "😀", "x"])
    #expect(h.tones == ["👍": "👍🏽"])
  }

  // MARK: typing

  func engine(_ start: String = "") throws -> (TypingEngine, FakeProxy) {
    let p = FakeProxy()
    p.text = start
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: KeyboardLayout(width: 402)))
    e.resync()
    return (e, p)
  }

  @Test func anEmojiLeavesTheWordBeforeItAsTyped() throws {
    let (e, p) = try engine("I said ")
    for ch in "teh" { e.character(String(ch)) }
    #expect(e.pendingAutocorrection == "the")
    e.emoji("😀")
    #expect(p.text == "I said teh😀")
    #expect(e.composing.isEmpty)
    e.space(now: 1)
    #expect(p.text == "I said teh😀 ")
  }

  @Test func anEmojiAfterAPickedSuggestionKeepsItsSpace() throws {
    let (e, p) = try engine("Hello ")
    for ch in "keyb" { e.character(String(ch)) }
    e.pick("keyboard")
    e.emoji("🎹")
    #expect(p.text == "Hello keyboard 🎹")
    e.character(",")
    #expect(p.text == "Hello keyboard 🎹,")  // punctuation after an emoji does not pull back a space
  }

  @Test func aSentenceCapitalStillFollowsAnEmojiAndAFullStop() throws {
    let (e, p) = try engine("Done")
    e.emoji("🎉")
    #expect(e.shift == .off)
    e.character(".")
    e.space(now: 1)
    #expect(e.shift == .on)
    #expect(p.text == "Done🎉. ")
  }

  @Test func deleteAfterAnEmojiDeletesTheEmoji() throws {
    let (e, p) = try engine("Hi ")
    e.emoji("👍🏽")
    e.delete()
    #expect(p.text == "Hi ")
  }
}

/// Emoji search and the bar's emoji, from the bundled keywords (CLDR 47 annotations, English and Spanish).
struct EmojiIndexTests {
  static func load(_ lang: String) -> Result<EmojiIndex, Error> {
    Result {
      try EmojiIndex(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../Keyboard/emoji-keywords-\(lang).txt").standardized)
    }
  }
  static let index = load("en")
  static let spanish = load("es")

  @Test func aWordNamesItsEmojiFirstAndAccentsAndCapitalsDoNotMatter() throws {
    let i = try Self.index.get()
    let es = try Self.spanish.get()
    #expect(i.count == 7207)
    #expect(es.count == 6283)
    #expect(i.emoji(for: "spain") == ["🇪🇸"])  // flags come from CLDR's derived annotations
    #expect(es.emoji(for: "España") == ["🇪🇸"])
    #expect(i.emoji(for: "pie") == ["🥧"])  // one file per language: "pie" is a foot in Spanish
    #expect(es.emoji(for: "pie") == ["🦶"])
    #expect(i.search("united king").first == "🇬🇧")
    #expect(i.emoji(for: "pizza").first == "🍕")
    #expect(i.emoji(for: "Pizza").first == "🍕")
    #expect(es.emoji(for: "perro").prefix(2) == ["🐕", "🐶"])
    #expect(es.emoji(for: "corazón") == es.emoji(for: "corazon"))
    #expect(!es.emoji(for: "corazon").isEmpty)
    #expect(i.emoji(for: "pizz") == [])  // whole words only
    #expect(i.emoji(for: "pizzas").first == "🍕")  // plurals fall back to the singular
    #expect(es.emoji(for: "perros").prefix(2) == ["🐕", "🐶"])
    #expect(i.emoji(for: "") == [])
  }

  @Test func searchFindsPrefixesThenEveryWord() throws {
    let i = try Self.index.get()
    #expect(i.search("pizz").first == "🍕")
    #expect(i.search("thumbs u").first == "👍")
    // no keyword begins "cat smil": the emoji both words find
    #expect(Set(i.search("cat smil")) == ["😺", "😸", "😼", "😻"])
    #expect(i.search("zzzz") == [])
    #expect(i.search("a", limit: 10).count == 10)
  }

  @Test func parsesASmallFileAndSkipsComments() {
    let i = EmojiIndex(data: Data("# c\nbee\t🐝\ncat\t🐈 😺\ncats\t🐈\n".utf8))
    #expect(i.count == 3)
    #expect(i.emoji(for: "cat") == ["🐈", "😺"])
    #expect(i.search("ca") == ["🐈", "😺"])
    #expect(i.emoji(for: "cats") == ["🐈"])  // the last line, without its newline
    #expect(i.emoji(for: "dog") == [])
  }
}

/// The bar's emoji while typing.
struct EmojiSuggestionTests {
  func engine(_ start: String = "", spanish: Bool = false) throws -> (TypingEngine, FakeProxy) {
    let p = FakeProxy()
    p.text = start
    let lex = spanish ? try Fixtures.spanish.get() : try Fixtures.english.get()
    let layout = KeyboardLayout(width: 402, language: spanish ? .spanish : .english)
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [lex], layout: layout))
    e.emojiIndexes = ["en": try EmojiIndexTests.index.get(), "es": try EmojiIndexTests.spanish.get()]
    e.resync()
    return (e, p)
  }

  /// Only the suggestion languages' keywords count: "pie" is 🥧 to an English typist, a foot to a Spanish one.
  @Test func theBarsEmojiFollowsTheLanguage() throws {
    let (en, _) = try engine("I baked a ")
    for ch in "pie" { en.character(String(ch)) }
    #expect(en.emojiSuggestion == "🥧")
    let (es, _) = try engine("Me duele el ", spanish: true)
    for ch in "pie" { es.character(String(ch)) }
    #expect(es.emojiSuggestion == "🦶")
  }

  @Test func theBarOffersTheWordsEmojiInItsLastSlot() throws {
    let (e, _) = try engine("I want ")
    for ch in "pizza" { e.character(String(ch)) }
    let bar = e.suggestions()
    #expect(bar.count == 3)
    #expect(bar.last == Suggestion(word: "🍕", kind: .emoji, score: 0))
  }

  @Test func pickingTheEmojiReplacesTheWord() throws {
    let (e, p) = try engine("I want ")
    for ch in "pizza" { e.character(String(ch)) }
    e.pick("🍕")
    #expect(p.text == "I want 🍕 ")
    #expect(e.composing.isEmpty)
  }

  @Test func shortWordsAndWordsWithNoEmojiGetNone() throws {
    let (e, _) = try engine("x ")
    for ch in "ok" { e.character(String(ch)) }
    #expect(e.emojiSuggestion == nil)
    e.space(now: 1)
    for ch in "the" { e.character(String(ch)) }  // a word, but no emoji's keyword
    #expect(!e.suggestions().contains { $0.kind == .emoji })
  }

  @Test func aTypoGetsTheEmojiOfItsCorrection() throws {
    let (e, _) = try engine("I want ")
    for ch in "pizzs" { e.character(String(ch)) }
    #expect(e.pendingAutocorrection == "pizzas")  // no keyword of its own: its singular names 🍕
    #expect(e.emojiSuggestion == "🍕")
  }
}
