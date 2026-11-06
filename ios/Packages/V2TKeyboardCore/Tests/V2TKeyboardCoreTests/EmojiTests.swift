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
