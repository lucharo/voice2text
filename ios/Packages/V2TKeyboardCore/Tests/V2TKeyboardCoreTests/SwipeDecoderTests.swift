import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

struct SwipeDecoderTests {
  /// The `n` commonest suggestible words of two or more letters, as typed (lowercase letters only).
  static func commonWords(_ lex: Lexicon, _ n: Int) -> [String] {
    var rows: [(String, Int)] = []
    for i in 0..<lex.count where lex.frequency(i) > 0 && lex.keyLength(i) >= 2 {
      let w = lex.word(i)
      if w == w.lowercased(), w.allSatisfy(\.isLetter) { rows.append((w, lex.frequency(i))) }
    }
    return rows.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(n).map(\.0)
  }

  struct Accuracy { var top1 = 0, top3 = 0, total = 0, misses: [String] = [], times: [Double] = [] }

  static func measure(_ lex: Lexicon, _ language: KeyboardLanguage, words n: Int, jitter: Double, seed: UInt64,
                      layout: KeyboardLayout? = nil) -> Accuracy {
    let layout = layout ?? KeyboardLayout(width: 402, language: language)
    let decoder = SwipeDecoder(lexicon: lex, layout: layout)
    var rng = SeededRandom(state: seed)
    var acc = Accuracy()
    for w in commonWords(lex, n) {
      acc.total += 1
      guard let trace = syntheticTrace(w, layout: layout, jitter: jitter, rng: &rng) else { acc.misses.append("\(w)->no trace"); continue }
      let t = ContinuousClock.now
      let got = decoder.decode(trace, limit: 3).map { $0.word.lowercased() }
      acc.times.append(Double((ContinuousClock.now - t).components.attoseconds) / 1e15)  // ms
      if got.first == w { acc.top1 += 1 } else if acc.misses.count < 25 { acc.misses.append("\(w)->\(got.first ?? "-")") }
      if got.contains(w) { acc.top3 += 1 }
    }
    return acc
  }

  @Test func cleanTracesDecodeToTheirWord() throws {
    let en = try Fixtures.english.get()
    let layout = KeyboardLayout(width: 402, language: .english)
    let decoder = SwipeDecoder(lexicon: en, layout: layout)
    var rng = SeededRandom(state: 1)
    for w in ["hello", "keyboard", "thanks", "tomorrow"] {
      let trace = try #require(syntheticTrace(w, layout: layout, jitter: 0, rng: &rng))
      #expect(decoder.decode(trace).first?.word == w)
    }
  }

  /// Known limit: with no sentence context the frequency prior can outrank a perfect trace of a rarer word.
  /// "dictation" (frequency 76) loses top place to "situation" but must stay in the suggestion bar.
  @Test func aPerfectTraceOfARarerWordStaysInTheSuggestionBar() throws {
    let layout = KeyboardLayout(width: 402, language: .english)
    let decoder = SwipeDecoder(lexicon: try Fixtures.english.get(), layout: layout)
    var rng = SeededRandom(state: 1)
    let trace = try #require(syntheticTrace("dictation", layout: layout, jitter: 0, rng: &rng))
    #expect(decoder.decode(trace, limit: 3).map(\.word).contains("dictation"))
  }

  @Test func spanishTracesThroughTheEnyeKeyDecodeToAccentedWords() throws {
    let es = try Fixtures.spanish.get()
    let layout = KeyboardLayout(width: 402, language: .spanish)
    let decoder = SwipeDecoder(lexicon: es, layout: layout)
    var rng = SeededRandom(state: 2)
    for w in ["mañana", "español", "niño", "también", "canción"] {
      let trace = try #require(syntheticTrace(w, layout: layout, jitter: 0, rng: &rng))
      #expect(decoder.decode(trace).first?.word == w)
    }
  }

  /// A swipe for "leaving" from a typing log (iPhone 17 Pro, English and Spanish on), as logged (48 of its 233
  /// points): it starts on l and ends by f. It was made while "E" was still being typed, the first letter of a
  /// mistyped "Eavin" left after deleting the rest, and the keyboard passed that letter as the word before.
  static let leaving: [CGPoint] = [
    (363, 82.3), (348, 86.7), (318, 77.7), (283.3, 57), (250.7, 38.3), (225, 29.7), (207.7, 28), (190, 24.3),
    (173.7, 20.3), (150.3, 14.7), (123.3, 12), (97, 15.3), (82, 25.7), (74, 35.3), (66.7, 44), (60.7, 52.3),
    (57.7, 60.3), (57.3, 67), (57.3, 73.3), (61, 84), (69.7, 98.7), (82, 116.7), (100.3, 135), (120.7, 146.7),
    (135.3, 148), (151, 140.3), (172.3, 115), (197.3, 88.7), (220.7, 72.3), (244.3, 59.3), (271.3, 41),
    (292.3, 23), (297, 15.3), (294, 15.7), (291, 20), (286.7, 32.7), (276.7, 65), (266.7, 96.3), (261.3, 117),
    (258.7, 125.3), (255.7, 127), (243.7, 127), (214.7, 114.3), (184.7, 95), (168.3, 80.7), (164.3, 72),
    (164.7, 69), (168, 69)
  ].map { CGPoint(x: $0.0, y: $0.1) }

  /// "E" read as a finished word is evidence for Spanish ("e", and), so every English word paid the language prior's
  /// cap and the Spanish "kirchhoff" won. Letters with no space before the cursor are a word in progress, which the
  /// swipe ends: they are not context. Once a space has finished them they are.
  @Test func lettersStillBeingTypedAreNotTheSwipesContext() throws {
    let layout = KeyboardLayout(width: 402, language: .english)
    let m = MultiSwipeDecoder([try Fixtures.english.get(), try Fixtures.spanish.get()].map { SwipeDecoder(lexicon: $0, layout: layout) })
    #expect(m.decode(Self.leaving, context: "E").first == "leaving")
    #expect(m.decode(Self.leaving, context: "E ").first == "kirchhoff")
  }

  @Test func aSingleTouchIsNotASwipe() throws {
    let decoder = SwipeDecoder(lexicon: try Fixtures.english.get(), layout: KeyboardLayout(width: 402))
    #expect(decoder.decode([CGPoint(x: 100, y: 30)]) == [])
  }

  /// Acceptance criterion 2: top-1 >= 90% and top-3 >= 97% on the 1,000 commonest words per language, with
  /// each key centre jittered by 0.25 key widths.
  @Test(arguments: [("en", KeyboardLanguage.english), ("es", KeyboardLanguage.spanish)])
  func noisyTracesOfCommonWordsMeetTheAccuracyTarget(lang: String, language: KeyboardLanguage) throws {
    let lex = try Fixtures.lexicon(lang)
    let acc = Self.measure(lex, language, words: 1000, jitter: 0.25, seed: 42)
    let p95 = acc.times.sorted()[Int(Double(acc.times.count) * 0.95)]
    print("swipe \(lang): top1 \(acc.top1)/\(acc.total) top3 \(acc.top3)/\(acc.total) p95 \(String(format: "%.1f", p95)) ms misses \(acc.misses)")
    #expect(Double(acc.top1) / Double(acc.total) >= 0.90)
    #expect(Double(acc.top3) / Double(acc.total) >= 0.97)
  }

  /// The same target on the iPad keyboards: 11-inch portrait and landscape, and the 13-inch full keyboard. Its keys are wider than tall, and
  /// the extra punctuation keys sit in the bottom letter row.
  @Test(arguments: [("en", KeyboardLanguage.english), ("es", KeyboardLanguage.spanish)])
  func noisyTracesMeetTheAccuracyTargetOnTheIPadKeyboard(lang: String, language: KeyboardLanguage) throws {
    let lex = try Fixtures.lexicon(lang)
    for (w, form, land) in [(CGFloat(834), KeyboardForm.pad, false), (1194, .pad, true), (1032, .padFull, false), (1376, .padFull, true)] {
      let layout = KeyboardLayout(width: w, language: language, form: form, landscape: land)
      let acc = Self.measure(lex, language, words: 1000, jitter: 0.25, seed: 42, layout: layout)
      print("swipe ipad \(form) \(lang) \(Int(w)): top1 \(acc.top1)/\(acc.total) top3 \(acc.top3)/\(acc.total)")
      #expect(Double(acc.top1) / Double(acc.total) >= 0.90)
      #expect(Double(acc.top3) / Double(acc.total) >= 0.97)
    }
  }
}

/// Tuning sweep, off by default: `V2T_TUNE=1 swift test -c release --filter SwipeTuning`.
struct SwipeTuning {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["V2T_TUNE"] != nil))
  func frequencyWeightSweep() throws {
    for lang in ["en", "es"] {
      let lex = try Fixtures.lexicon(lang)
      for (w, es) in [(5.0, 100.0), (5.0, 0.4), (5.0, 0.6), (5.0, 0.9), (7.5, 0.6), (3.0, 0.6)] {
        let layout = KeyboardLayout(width: 402, language: lang == "es" ? .spanish : .english)
        let d = SwipeDecoder(lexicon: lex, layout: layout)
        d.frequencyWeight = w
        d.endpointStd = es
        var rng = SeededRandom(state: 7)
        var t1 = 0, t3 = 0, n = 0, times: [Double] = []
        for word in SwipeDecoderTests.commonWords(lex, 600) {
          guard let tr = syntheticTrace(word, layout: layout, jitter: 0.25, rng: &rng) else { continue }
          let t = ContinuousClock.now
          let got = d.decode(tr, limit: 3).map { $0.word.lowercased() }
          times.append(Double((ContinuousClock.now - t).components.attoseconds) / 1e15)
          n += 1; if got.first == word { t1 += 1 }; if got.contains(word) { t3 += 1 }
        }
        times.sort()
        print("tune \(lang) w=\(w) es=\(es): top1 \(t1)/\(n) top3 \(t3)/\(n) p50 \(String(format: "%.1f", times[n / 2])) p95 \(String(format: "%.1f", times[n * 95 / 100])) ms")
      }
    }
  }
}

