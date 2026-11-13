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
/// It runs in an optimised build only (a debug build takes over half an hour on the whole sets):
/// `swift test -c release -Xswiftc -enable-testing --filter RealTypoEval 2>&1 | grep '^realtypo'`.
enum RealTypoEval {
  #if DEBUG
  static let optimised = false
  #else
  static let optimised = true
  #endif

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
                             keyTimes: inout [Double], configure: (Suggester) -> Void = { _ in }) -> Result {
    var r = Result(name: name)
    for sentence in sentences {
      let p = FakeProxy()
      let s = Suggester(lexicons: lexicons, layout: layout)
      configure(s)
      let e = TypingEngine(proxy: p, suggester: s)
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
        let d = (ContinuousClock.now - start).components
        keyTimes.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
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

  static func pct(_ a: Int, _ n: Int) -> String { n == 0 ? "-" : String(format: "%.1f%% (%d)", 100 * Double(a) / Double(n), a) }

  static func stats(_ v: [Double]) -> String {
    let s = v.sorted()
    return String(format: "mean %.3f, p50 %.3f, p95 %.3f, p99 %.3f, max %.2f ms", s.reduce(0, +) / Double(s.count),
                  s[s.count / 2], s[s.count * 95 / 100], s[s.count * 99 / 100], s[s.count - 1])
  }
}

struct RealTypoEvalTests {
  @Test(.enabled(if: RealTypoEval.optimised, "slow in a debug build: run swift test -c release -Xswiftc -enable-testing --filter RealTypoEval"))
  func realMisspellingsAndRealText() throws {
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
      print("realtypo | \(r.name) | \(r.words) | \(RealTypoEval.pct(r.changed, r.words))")
      print("realtypo-changed | \(r.name) | \(r.changedExamples)")
    }
    print("realtypo-latency | key + bar + bold slot, Mac | \(RealTypoEval.stats(keyTimes)) over \(keyTimes.count) keys")
    // floors a couple of points under the measured values (2026-11-12), so a regression fails
    func share(_ a: Int, _ n: Int) -> Double { 100 * Double(a) / Double(max(1, n)) }
    #expect(share(rows[0].fixed, rows[0].scored) >= 86, "English misspellings fixed")
    #expect(share(rows[0].wrong, rows[0].scored) <= 6, "English misspellings made a wrong word")
    #expect(share(rows[1].fixed, rows[1].scored) >= 87.5, "Spanish misspellings fixed")
    #expect(share(rows[1].wrong, rows[1].scored) <= 6, "Spanish misspellings made a wrong word")
    #expect(share(text[0].changed, text[0].words) <= 0.5, "correct English words changed")
    #expect(share(text[1].changed, text[1].words) <= 2.5, "correct Spanish words changed")
    #expect(share(text[2].changed, text[2].words) <= 0.5, "correct English words changed with Spanish on")
  }
}

/// RealTypoEval's rows under other autocorrect weights, off by default:
///
///     V2T_TYPO_TUNE='off:sub=inf,vow=inf;s5:sub=5,vow=3.5' \
///       swift test -c release -Xswiftc -enable-testing --filter RealTypoTuning
///
/// Keys: sub/vow the substitution penalties, edit the skip/insert penalty, margin the autocorrect margin,
/// fw the frequency weight, pn the proper-noun penalty, edits the most edits, first the extra cost of skipping
/// the first touch, last the cost of a last letter left off, floor the lowest score a non-word's correction may
/// have (write -inf as "floor=-inf"), lead the nats a completion must beat a correction by for the word to be
/// left as unfinished, beam the beam width per lexicon, runner the nats the best correction must lead the next
/// word by, std the touch spread in key widths, nfloor the least a neighbouring key costs and ncut the furthest
/// a key may be from the touch, in key widths. The third row types the English misspellings with Spanish on as
/// well, as a bilingual typist has it. `NoisyTypingTuning` reads the same settings.
/// short and fgap are QualityTuning's.
/// space: the nats two words typed without the space between them pay against the best correction.
/// cfloor: the score under which a correction of two words run together is not applied.
/// tapcost and tapgap: the ambiguous-tap rule's cost and gap.
struct RealTypoTuning {
  static let spec = ProcessInfo.processInfo.environment["V2T_TYPO_TUNE"]

  /// The settings of `V2T_TYPO_TUNE`, by name: "name:key=value,key=value;name:...".
  static func settings(_ spec: String) -> [(name: String, apply: (Suggester) -> Void)] {
    spec.split(separator: ";").map { item in
      let parts = item.split(separator: ":", maxSplits: 1)
      let pairs = parts.count > 1 ? parts[1].split(separator: ",").map { $0.split(separator: "=") } : []
      return (String(parts[0]), { s in
        for p in pairs {
          let v = p[1] == "inf" ? Double.infinity : p[1] == "-inf" ? -Double.infinity : Double(p[1])!
          switch p[0] {
          case "sub": s.substitutionPenalty = v
          case "vow": s.vowelSubstitutionPenalty = v
          case "edit": s.editPenalty = v
          case "margin": s.autocorrectMargin = v
          case "fw": s.frequencyWeight = v
          case "pn": s.properNounPenalty = v
          case "edits": s.maxEdits = Int(v)
          case "first": s.firstTouchPenalty = v
          case "last": s.lastLetterPenalty = v
          case "floor": s.correctionFloor = v
          case "lead": s.completionLead = v
          case "beam": s.beamWidth = Int(v)
          case "runner": s.runnerUpLead = v
          case "std": s.touchStd = v
          case "nfloor": s.neighbourFloor = v
          case "ncut": s.neighbourCutoff = v
          case "space": s.missingSpacePenalty = v
          case "cfloor": s.compoundFloor = v
          case "short": s.languagePrior.shortWordCap = v
          case "fgap": s.followerLanguageGap = v
          case "tapcost": s.ambiguousTapCost = v
          case "tapgap": s.ambiguousTapGap = v
          default: Issue.record("unknown key \(p[0])")
          }
        }
      })
    }
  }

  @Test(.enabled(if: spec != nil))
  func table() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let enLayout = KeyboardLayout(width: 402, language: .english), esLayout = KeyboardLayout(width: 402, language: .spanish)
    let enRows = try RealTypoEval.misspellings("en"), esRows = try RealTypoEval.misspellings("es")
    let enText = try RealTypoEval.sentences("en"), esText = try RealTypoEval.sentences("es")
    for (name, apply) in Self.settings(Self.spec!) {
      func make(_ lex: [Lexicon], _ layout: KeyboardLayout) -> Suggester {
        let s = Suggester(lexicons: lex, layout: layout)
        apply(s)
        return s
      }
      for r in [RealTypoEval.misspellingRow("EN", enRows, suggester: make([en], enLayout), context: "I think the "),
                RealTypoEval.misspellingRow("ES", esRows, suggester: make([es], esLayout), context: "Creo que el "),
                RealTypoEval.misspellingRow("EN, with ES on", enRows, suggester: make([en, es], enLayout), context: "I think the ")] {
        print("typotune | \(name) | \(r.name) | fixed \(RealTypoEval.pct(r.fixed, r.scored)) | wrong \(RealTypoEval.pct(r.wrong, r.scored)) | top-3 \(RealTypoEval.pct(r.top3, r.scored))")
      }
      var times: [Double] = []
      for r in [RealTypoEval.correctTextRow("EN text", enText, lexicons: [en], layout: enLayout, keyTimes: &times, configure: apply),
                RealTypoEval.correctTextRow("ES text", esText, lexicons: [es], layout: esLayout, keyTimes: &times, configure: apply),
                RealTypoEval.correctTextRow("EN text, with ES on", enText, lexicons: [en, es], layout: enLayout, keyTimes: &times, configure: apply)] {
        print("typotune | \(name) | \(r.name) | changed \(RealTypoEval.pct(r.changed, r.words))")
      }
    }
  }
}
