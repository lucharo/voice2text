import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Autocorrect against misspellings people really made and text people really wrote, rather than the
/// synthetic noisy taps of SuggesterTests. The sets come from `ios/tools/fetch_misspellings.py` at pinned
/// revisions (ios/setup.sh runs it):
///
/// - English: Wikipedia's list of common misspellings (made by Wikipedia editors), CC BY-SA 4.0.
/// - Spanish: Spanish Wikipedia's spelling-bot list (mostly missing accents), CC BY-SA 4.0.
/// - Correct text: 1,043 Tatoeba sentences a language (CC BY 2.0 FR), typed through the engine.
///
/// The misspellings were typed on physical keyboards, so the taps here are at the key centres of the letters
/// as misspelt: the measure is the language side of autocorrect, not the touch model.
///
/// Print the table: `swift test --filter RealTypoEval 2>&1 | grep '^realtypo'`.
enum RealTypoEval {
  static let dir = ProcessInfo.processInfo.environment["V2T_MISSPELLING_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../build/misspellings").standardized

  static func file(_ name: String) throws -> String {
    let url = dir.appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path()) else {
      throw Lexicon.FormatError(description: "missing \(url.path()); run ios/tools/fetch_misspellings.py ios/build/misspellings")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// (misspelling, the words it may have meant)
  static func misspellings(_ lang: String) throws -> [(String, [String])] {
    try file("\(lang).tsv").split(separator: "\n").compactMap { line in
      let p = line.split(separator: "\t")
      return p.count == 2 ? (String(p[0]), p[1].split(separator: ",").map(String.init)) : nil
    }
  }

  static func sentences(_ lang: String) throws -> [String] {
    try file("\(lang)-sentences.txt").split(separator: "\n").map(String.init)
  }

  struct Result {
    var name: String
    var total = 0, realWord = 0, outOfVocabulary = 0
    var fixed = 0, wrong = 0, untouched = 0, top3 = 0
    var wrongExamples: [String] = [], missExamples: [String] = []
    var words = 0, changed = 0
    var changedExamples: [String] = []

    var scored: Int { total - realWord - outOfVocabulary }
  }

  static func taps(_ word: String, _ layout: KeyboardLayout) -> [TypedKey] {
    word.map { ch in TypedKey(ch, at: layout.keys.first { $0.label == String(ch).lowercased() }?.center) }
  }

  /// Each misspelling typed on its own after `context`: fixed (autocorrect writes a meant word), wrong
  /// (another word), untouched, and whether a meant word is among the bar's three. A misspelling that is
  /// itself a word in the lexicon (a real-word error) is counted apart and should be left alone; one whose
  /// meant words are all missing from the lexicon cannot be fixed by any list-based keyboard and is skipped.
  static func misspellingRow(_ name: String, _ rows: [(String, [String])], suggester s: Suggester, context: String) -> Result {
    var r = Result(name: name)
    let ctx = TypingContext(before: context)
    for (typo, targets) in rows {
      r.total += 1
      if s.lexicons.contains(where: { $0.entry(of: typo) != nil }) { r.realWord += 1; continue }
      let want = Set(targets.map { $0.lowercased() })
      guard targets.contains(where: { t in s.lexicons.contains { $0.entry(of: t) != nil } }) else { r.outOfVocabulary += 1; continue }
      let typed = taps(typo, s.layout)
      let got = s.autocorrection(for: typed, context: ctx)
      if let g = got, want.contains(g.lowercased()) { r.fixed += 1 }
      else if let g = got { r.wrong += 1; if r.wrongExamples.count < 25 { r.wrongExamples.append("\(typo)->\(g) (\(targets.joined(separator: "/")))") } }
      else { r.untouched += 1; if r.missExamples.count < 25 { r.missExamples.append("\(typo) (\(targets.joined(separator: "/")))") } }
      if s.suggestions(for: typed, context: ctx, limit: 3).contains(where: { want.contains($0.word.lowercased()) }) { r.top3 += 1 }
    }
    return r
  }

  /// Every sentence typed through the engine as written (capitals typed as capitals, punctuation and spaces
  /// as keys, taps at key centres), counting the words autocorrect changed. Each sentence is a fresh field.
  static func correctTextRow(_ name: String, _ sentences: [String], lexicons: [Lexicon], layout: KeyboardLayout,
                             keyTimes: inout [Double]) -> Result {
    var r = Result(name: name)
    for sentence in sentences {
      let p = FakeProxy()
      let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: lexicons, layout: layout))
      e.resync()
      var t: TimeInterval = 0
      for ch in sentence {
        t += 1
        let start = ContinuousClock.now
        if ch == " " { e.space(now: t) } else {
          e.character(String(ch), at: layout.keys.first { $0.label == String(ch).lowercased() }?.center, now: t)
        }
        // what the keyboard does after every key: refresh the bar and its bold slot
        _ = e.suggestions()
        _ = e.pendingAutocorrection
        keyTimes.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
      }
      e.space(now: t + 1)
      let want = sentence.split(separator: " "), got = p.text.split(separator: " ")
      r.words += want.count
      for (a, b) in zip(want, got) where a != b {
        r.changed += 1
        if r.changedExamples.count < 30 { r.changedExamples.append("\(a)->\(b)") }
      }
      if want.count != got.count { r.changed += abs(want.count - got.count) }
    }
    return r
  }

  static func pct(_ a: Int, _ n: Int) -> String { n == 0 ? "-" : String(format: "%.1f%%", 100 * Double(a) / Double(n)) }

  static func stats(_ v: [Double]) -> String {
    let s = v.sorted()
    return String(format: "mean %.3f, p50 %.3f, p95 %.3f, p99 %.3f, max %.2f ms", s.reduce(0, +) / Double(s.count),
                  s[s.count / 2], s[s.count * 95 / 100], s[s.count * 99 / 100], s[s.count - 1])
  }
}

struct RealTypoEvalTests {
  @Test func realMisspellingsAndRealText() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let enLayout = KeyboardLayout(width: 402, language: .english), esLayout = KeyboardLayout(width: 402, language: .spanish)
    let rows = [
      RealTypoEval.misspellingRow("EN Wikipedia misspellings, EN", try RealTypoEval.misspellings("en"),
                                  suggester: Suggester(lexicons: [en], layout: enLayout), context: "I think the "),
      RealTypoEval.misspellingRow("ES Wikipedia misspellings, ES", try RealTypoEval.misspellings("es"),
                                  suggester: Suggester(lexicons: [es], layout: esLayout), context: "Creo que el "),
    ]
    print("realtypo | set | misspellings scored | fixed | wrong word | left as typed | meant word in bar (top-3) | real-word errors skipped | meant word not in lexicon")
    for r in rows {
      print("realtypo | \(r.name) | \(r.scored) | \(RealTypoEval.pct(r.fixed, r.scored)) | \(RealTypoEval.pct(r.wrong, r.scored)) | \(RealTypoEval.pct(r.untouched, r.scored)) | \(RealTypoEval.pct(r.top3, r.scored)) | \(r.realWord) | \(r.outOfVocabulary)")
      print("realtypo-wrong | \(r.name) | \(r.wrongExamples)")
      print("realtypo-untouched | \(r.name) | \(r.missExamples)")
    }
    var keyTimes: [Double] = []
    let text = [
      RealTypoEval.correctTextRow("EN Tatoeba sentences, EN", try RealTypoEval.sentences("en"), lexicons: [en], layout: enLayout, keyTimes: &keyTimes),
      RealTypoEval.correctTextRow("ES Tatoeba sentences, ES", try RealTypoEval.sentences("es"), lexicons: [es], layout: esLayout, keyTimes: &keyTimes),
      RealTypoEval.correctTextRow("EN Tatoeba sentences, EN+ES", try RealTypoEval.sentences("en"), lexicons: [en, es], layout: enLayout, keyTimes: &keyTimes),
    ]
    print("realtypo | correct text | words | words autocorrect changed")
    for r in text {
      print("realtypo | \(r.name) | \(r.words) | \(r.changed) (\(RealTypoEval.pct(r.changed, r.words)))")
      print("realtypo-changed | \(r.name) | \(r.changedExamples)")
    }
    print("realtypo-latency | key + bar + bold slot, Mac | \(RealTypoEval.stats(keyTimes)) over \(keyTimes.count) keys")
  }
}
