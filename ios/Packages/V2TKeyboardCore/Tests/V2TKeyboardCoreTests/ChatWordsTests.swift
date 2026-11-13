import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// The chat abbreviations ios/tools/chat_words_en.txt adds to the English lexicon, on the touches of the owner's
/// fourth typing log. The control is the same lexicon with those words taken out again.
struct ChatWordsTests {
  static let layout = KeyboardLayout(width: 402, language: .english)
  static let list = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../tools/chat_words_en.txt").standardized

  static func words() throws -> [String] {
    try String(contentsOf: list, encoding: .utf8).split(separator: "\n")
      .filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { String($0.split(separator: "\t")[0]) }
  }

  static func keys(_ touches: [(Character, Double, Double)]) -> [TypedKey] { touches.map { TypedKey($0.0, at: CGPoint(x: $0.1, y: $0.2)) } }
  // line 5803: "idk", with I'd in bold before the list
  static let idk = keys([("i", 292.3, 24), ("d", 118, 88), ("k", 320.3, 86.7)])
  // lines 4212, 9915 and (in the build 124 log) 4144
  static let btw = keys([("b", 239.3, 132.7), ("t", 183, 42.3), ("w", 66.7, 30)])
  static let pls = keys([("p", 371.3, 45.7), ("l", 364.7, 83.7), ("s", 71.7, 73)])

  /// The English lexicon without the list's words, and without its next-word statistics. "pls" was in the AOSP
  /// list at frequency 0 (a word never suggested); here it is taken out with the rest.
  static func withoutChatWords() throws -> Lexicon {
    let en = try Fixtures.english.get(), chat = Set(try words())
    return try Lexicon.build((0..<en.count).compactMap { chat.contains(en.word($0)) ? nil : (en.word($0), en.frequency($0)) }, language: "en")
  }

  func engine(_ english: Lexicon, before: String, _ typed: [TypedKey]) throws -> TypingEngine {
    let p = FakeProxy()
    p.text = before
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [english, try Fixtures.spanish.get()], layout: Self.layout))
    e.resync()
    for k in typed { e.character(String(k.character), at: k.point) }
    return e
  }

  @Test func everyWordOfTheListIsAnEnglishWord() throws {
    let en = try Fixtures.english.get()
    for w in try Self.words() { #expect(en.frequency(of: w) == 60, "\(w)") }
  }

  @Test func idkStaysIdk() throws {
    let e = try engine(try Fixtures.english.get(), before: "ok ", Self.idk)
    #expect(e.pendingAutocorrection == nil)
    e.space()
    #expect((e.proxy as! FakeProxy).text == "ok idk ")
    let before = try engine(try Self.withoutChatWords(), before: "ok ", Self.idk)
    #expect(before.pendingAutocorrection == "I'd")
  }

  @Test(arguments: [(btw, "lgs "), (pls, "the "), (keys([("O", 348.3, 47), ("f", 151, 95), ("c", 150, 119.3)]), "")])
  func chatWordsAreWordsInTheBar(typed: [TypedKey], before: String) throws {
    let word = String(typed.map(\.character))
    let s = Suggester(lexicons: [try Fixtures.english.get(), try Fixtures.spanish.get()], layout: Self.layout)
    let bar = s.suggestions(for: typed, context: TypingContext(before: before))
    #expect(bar.first { $0.word == word }.map { $0.kind == .typed && $0.score > -.infinity } == true, "\(bar)")
    let old = Suggester(lexicons: [try Self.withoutChatWords(), try Fixtures.spanish.get()], layout: Self.layout)
    #expect(old.suggestions(for: typed, context: TypingContext(before: before)).first { $0.word == word }?.score == -.infinity)
  }

  /// The swipe at line 5750 of the log, meant as "idk" (the trace the keyboard decoded).
  static let idkSwipe: [CGPoint] = [
    (305, 24.7), (294, 21.3), (289, 21.3), (283.3, 21.3), (276, 21.3), (266.7, 22.3), (255.3, 24.3), (242.3, 28.3),
    (235.7, 30.3), (222, 35), (209, 40), (196.7, 44.7), (184.3, 49.3), (173, 54.3), (162, 59), (152.3, 64),
    (144, 68.7), (137.3, 73), (131.7, 77.3), (126.3, 80.7), (121, 83.7), (116.7, 85.3), (112, 86), (108.3, 86),
    (106.3, 86), (103.3, 86), (101, 86), (99.7, 86), (99, 85.7), (101, 85.3), (105.3, 85), (112.3, 83.7),
    (122.7, 82), (135.7, 79.3), (151, 76.7), (167.3, 74.3), (182.3, 72.7), (196.3, 72), (209, 71.7), (220.3, 71.7),
    (226.7, 71.7), (238.7, 71.7), (251, 71.7), (263.7, 71.7), (276.7, 71.7), (289.3, 71.7), (300.7, 71.7),
    (310.3, 71),
  ].map { CGPoint(x: $0.0, y: $0.1) }

  @Test func theSwipeForIdkMakesIdk() throws {
    let es = try Fixtures.spanish.get()
    func decode(_ en: Lexicon) -> [String] { MultiSwipeDecoder([en, es].map { SwipeDecoder(lexicon: $0, layout: Self.layout) }).decode(Self.idkSwipe) }
    #expect(decode(try Fixtures.english.get()).first == "idk")
    #expect(try decode(Self.withoutChatWords()).prefix(2) == ["oak", "irk"])
  }
}
