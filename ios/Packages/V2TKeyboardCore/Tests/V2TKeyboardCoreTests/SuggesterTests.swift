import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Taps at the key centres for `word` on `layout` (what a perfect typist sends).
func taps(_ word: String, _ layout: KeyboardLayout) -> [TypedKey] {
  word.map { ch in
    let k = layout.keys.first { $0.label == String(ch).lowercased() }
    return TypedKey(ch, at: k?.center)
  }
}

/// Taps scattered around each intended key with `std` key widths of Gaussian noise; the character is the key
/// each touch actually lands on, as the keyboard would type it.
func noisyTaps(_ word: String, _ layout: KeyboardLayout, std: Double, rng: inout SeededRandom) -> [TypedKey] {
  word.map { ch in
    guard let k = layout.keys.first(where: { $0.label == String(ch) }) else { return TypedKey(ch) }
    let u = Double(layout.unitWidth)
    let p = CGPoint(x: k.center.x + CGFloat(rng.gaussian() * std * u), y: k.center.y + CGFloat(rng.gaussian() * std * u))
    let hit = layout.key(at: p)
    if case .character(let c)? = hit?.action, let first = c.first { return TypedKey(first, at: p) }
    return TypedKey(ch, at: p)
  }
}

struct SuggesterTests {
  let en = KeyboardLayout(width: 402, language: .english)
  let es = KeyboardLayout(width: 402, language: .spanish)

  func english() throws -> Suggester { Suggester(lexicons: [try Fixtures.english.get()], layout: en) }
  func spanish() throws -> Suggester { Suggester(lexicons: [try Fixtures.spanish.get()], layout: es) }

  @Test(arguments: [("teh", "the"), ("helo", "hello"), ("recieve", "receive"), ("becuase", "because"), ("adn", "and"),
                    ("dont", "don't"), ("Helo", "Hello"), ("i", "I"), ("keybaord", "keyboard"), ("tomorow", "tomorrow")])
  func classicEnglishTyposAreCorrected(typed: String, expected: String) throws {
    #expect(try english().autocorrection(for: taps(typed, en)) == expected)
  }

  @Test(arguments: [("qeu", "que"), ("cancion", "canción"), ("tambien", "también"), ("manana", "mañana"), ("graicas", "gracias")])
  func classicSpanishTyposAreCorrected(typed: String, expected: String) throws {
    #expect(try spanish().autocorrection(for: taps(typed, es)) == expected)
  }

  /// The search sees letters only: a word with digits is never autocorrected, or the digits would vanish.
  @Test(arguments: ["hello1", "teh2", "4helo"])
  func wordsWithDigitsAreNotAutocorrected(typed: String) throws {
    #expect(try english().autocorrection(for: taps(typed, en)) == nil)
  }

  @Test func realWordsAreLeftAlone() throws {
    let s = try english()
    for w in ["the", "hello", "form", "from", "voice", "text", "iPhone"] { #expect(s.autocorrection(for: taps(w, en)) == nil, "\(w)") }
    #expect(try spanish().autocorrection(for: taps("como", es)) == nil)
  }

  @Test func aLearnedWordIsNeverCorrected() throws {
    #expect(try english().autocorrection(for: taps("fluide", en), learned: ["fluide"]) == nil)
  }

  @Test func suggestionsOfferCompletionsAndKeepTheTypedWord() throws {
    let got = try english().suggestions(for: taps("keyb", en)).map(\.word)
    #expect(got.contains("keyboard"))
    #expect(got.contains("keyb"))
  }

  @Test func capitalsCarryOver() {
    #expect(Suggester.applyCase(of: "Helo", to: "hello") == "Hello")
    #expect(Suggester.applyCase(of: "HELO", to: "hello") == "HELLO")
    #expect(Suggester.applyCase(of: "iphone", to: "iPhone") == "iPhone")
  }

  /// Acceptance criterion 3: on 200 typo'd words (noisy taps whose keys differ from the word) autocorrect
  /// restores the word, and on 1,000 correctly typed common words it changes no more than 2%.
  @Test(arguments: ["en", "es"])
  func autocorrectFixesTyposAndRarelyBreaksCorrectWords(lang: String) throws {
    let layout = lang == "es" ? es : en
    let lex = try Fixtures.lexicon(lang)
    let s = Suggester(lexicons: [lex], layout: layout)
    let common = SwipeDecoderTests.commonWords(lex, 1000)
    var wrong: [String] = []
    for w in common where s.autocorrection(for: taps(w, layout)) != nil { wrong.append(w) }
    var rng = SeededRandom(state: 9)
    var fixed = 0, typos = 0, misses: [String] = []
    for w in common.filter({ $0.count >= 4 }) where typos < 200 {
      let t = noisyTaps(w, layout, std: 0.45, rng: &rng)
      let typedWord = String(t.map(\.character))
      guard typedWord != w else { continue }
      typos += 1
      let got = s.autocorrection(for: t)
      if got == w { fixed += 1 } else if misses.count < 20 { misses.append("\(typedWord)->\(got ?? "-") (\(w))") }
    }
    print("autocorrect \(lang): fixed \(fixed)/\(typos), broke \(wrong.count)/\(common.count) \(wrong.prefix(15)) misses \(misses)")
    #expect(Double(wrong.count) / Double(common.count) <= 0.02)
    #expect(Double(fixed) / Double(typos) >= 0.75)
  }
}
