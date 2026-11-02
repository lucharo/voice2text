import Foundation
import Testing
@testable import V2TCleanup

/// golden.json holds the real Python's outputs (ios/tools/cleanup_golden.py); every case must match byte for
/// byte. Strings are compared as UTF-8, since Swift's `==` would call NFC and NFD forms of a word equal.
struct Golden: Decodable {
  struct Counts: Decodable, Equatable { let restored: Int, reverted: Int, removed: Int }
  struct Keep: Decodable { let raw: String, clean: String, vocabulary: [String], text: String, counts: Counts }
  struct Sounds: Decodable { let spoken: String, written: String, alike: Bool }
  struct Chunk: Decodable { let text: String, max_words: Int, chunks: [String] }
  struct Guard: Decodable { let raw: String, clean: String, mode: String, ok: Bool }
  struct Message: Decodable { let role: String, content: String }
  struct Messages: Decodable { let text: String, mode: String, vocabulary: [String], messages: [Message] }
  struct Bare: Decodable { let token: String, bare: String }
  struct Opcodes: Decodable { let a: [String], b: [String], autojunk: Bool, opcodes: [[OpcodeField]] }
  struct Ratio: Decodable { let a: String, b: String, ratio: Double }

  enum OpcodeField: Decodable, Equatable {
    case tag(String), index(Int)
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let i = try? c.decode(Int.self) { self = .index(i) } else { self = .tag(try c.decode(String.self)) }
    }
  }

  let unicode: String
  let keep_spoken_words: [Keep]
  let sounds_alike: [Sounds]
  let chunk_text: [Chunk]
  let within_length_guard: [Guard]
  let cleanup_messages: [Messages]
  let bare: [Bare]
  let opcodes: [Opcodes]
  let ratio: [Ratio]
  let word_char_ranges: [[UInt32]]
  let digit_ranges: [[UInt32]]
  let space_ranges: [[UInt32]]

  static let shared: Golden = {
    let url = Bundle.module.url(forResource: "golden", withExtension: "json")!
    return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
  }()
}

/// UTF-8 bytes, so equality is Python's code-point equality; prints as the string.
struct Exact: Equatable, CustomStringConvertible {
  let bytes: [UInt8]
  init(_ s: String) { bytes = Array(s.utf8) }
  var description: String { String(decoding: bytes, as: UTF8.self).debugDescription }
}

private func mode(_ name: String) -> CleanupMode { CleanupMode(rawValue: name)! }

@Suite struct GoldenTests {
  let golden = Golden.shared

  @Test func fixtureHasEnoughCases() {
    let count =
      golden.keep_spoken_words.count + golden.sounds_alike.count + golden.chunk_text.count
      + golden.within_length_guard.count + golden.cleanup_messages.count
    #expect(count >= 80)
  }

  @Test func keepSpokenWordsMatchesPython() {
    for c in golden.keep_spoken_words {
      let got = keepSpokenWords(raw: c.raw, clean: c.clean, vocabulary: c.vocabulary)

      let counts = Golden.Counts(
        restored: got.counts.restored, reverted: got.counts.reverted, removed: got.counts.removed)
      #expect(Exact(got.text) == Exact(c.text), "raw: \(c.raw.debugDescription) clean: \(c.clean.debugDescription)")
      #expect(counts == c.counts, "raw: \(c.raw.debugDescription) clean: \(c.clean.debugDescription)")
    }
  }

  @Test func soundsAlikeMatchesPython() {
    for c in golden.sounds_alike {
      #expect(soundsAlike(c.spoken, c.written) == c.alike, "\(c.spoken) / \(c.written)")
    }
  }

  @Test func chunkTextMatchesPython() {
    for c in golden.chunk_text {
      let got = chunkText(c.text, maxWords: c.max_words)

      #expect(got.map(Exact.init) == c.chunks.map(Exact.init), "\(c.text.prefix(40).debugDescription)")
    }
  }

  @Test func lengthGuardMatchesPython() {
    for c in golden.within_length_guard {
      #expect(withinLengthGuard(raw: c.raw, clean: c.clean, mode: mode(c.mode)) == c.ok, "\(c)")
    }
  }

  @Test func cleanupMessagesMatchPython() {
    for c in golden.cleanup_messages {
      let got = CleanupPrompt.messages(for: c.text, mode: mode(c.mode), vocabulary: c.vocabulary)

      #expect(got.map { [Exact($0.role), Exact($0.content)] } == c.messages.map { [Exact($0.role), Exact($0.content)] })
    }
  }

  @Test func bareMatchesPython() {
    for c in golden.bare {
      #expect(Exact(String(py: bare(c.token))) == Exact(c.bare), "\(c.token.debugDescription)")
    }
  }

  @Test func opcodesMatchPython() {
    for c in golden.opcodes {
      let got = SequenceMatcher(a: c.a, b: c.b, autojunk: c.autojunk).opcodes().map {
        [Golden.OpcodeField.tag($0.tag.rawValue), .index($0.i1), .index($0.i2), .index($0.j1), .index($0.j2)]
      }

      #expect(got == c.opcodes, "a: \(c.a.count) b: \(c.b.count) autojunk: \(c.autojunk)")
    }
  }

  @Test func ratioMatchesPython() {
    for c in golden.ratio {
      #expect(SequenceMatcher(a: c.a.py, b: c.b.py).ratio() == c.ratio, "\(c.a.prefix(20)) / \(c.b.prefix(20))")
    }
  }

  /// Python's `\w`, `str.isdigit()` and `str.isspace()` over every code point both Unicode versions assign
  /// alike (those newer than Python's Unicode are skipped).
  @Test(arguments: ["word", "digit", "space"])
  func characterClassesMatchPython(_ name: String) {
    let (ranges, predicate): ([[UInt32]], (Unicode.Scalar) -> Bool) =
      switch name {
      case "word": (golden.word_char_ranges, Py.isWord)
      case "digit": (golden.digit_ranges, Py.isDigit)
      default: (golden.space_ranges, Py.isSpace)
      }
    let parts = golden.unicode.split(separator: ".").map { Int($0)! }
    let pythonAge = (major: parts[0], minor: parts[1])
    var expected = Set<UInt32>()
    for r in ranges { for v in r[0]...r[1] { expected.insert(v) } }

    var mismatches: [String] = []
    for v in UInt32(0)...0x10FFFF {
      guard let s = Unicode.Scalar(v) else { continue }
      if let age = s.properties.age, (age.major, age.minor) > pythonAge { continue }
      if predicate(s) != expected.contains(v) { mismatches.append(String(v, radix: 16)) }
    }

    #expect(mismatches == [])
  }
}
