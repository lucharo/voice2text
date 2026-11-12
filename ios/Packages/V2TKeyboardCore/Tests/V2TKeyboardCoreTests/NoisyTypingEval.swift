import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Autocorrect on real phone taps: the touch model, which RealTypoEval's key-centre taps cannot measure. The taps
/// are the phone group of Vertanen and Kristensson's noisy-typing dataset (CC BY 4.0, https://osf.io/5xwng/),
/// fetched by `ios/tools/fetch_noisy_typing.py` (ios/setup.sh runs it): Enron email sentences copied on an iPhone 4
/// or a Nexus 4 keyboard, force aligned by the authors to the words they mean, so each word can be typed on its own.
///
/// They were typed a whole sentence before any recognition, often with no key popups, some on keyboards a third
/// or a sixth of a phone's: noisier than typing with a keyboard that shows each key. `full-size, key popups` is the
/// part closest to v2t (vt_exp1's feedback condition, all of vt_exp2, vt_exp3's normal keyboard).
///
/// Mapping: each dataset keyboard's coordinates go onto v2t's 402 pt iPhone layout by one straight line for x and
/// one for y, the least-squares fit of its 26 letter centres onto v2t's (both layouts stagger their rows by half a
/// key, so the fit is exact on the centres). A touch thus keeps its offset from the key in key pitches; v2t's keys
/// are wider for their height than the dataset's, so an offset keeps its share of the pitch, not its shape. As on
/// the keyboard, the key is where the finger landed (`KeyboardLayout.key(at:)`) and the point the suggester scores
/// is where it lifted. A touch that lands on a v2t key the dataset's keyboard did not have (shift, delete, the
/// bottom row) counts as the letter key with the nearest centre, as the dataset's own keyboard read it; how many
/// did is printed. Spaces are typed as the space key between words: the word-aligned taps hold letters only, and
/// the references have no capitals, digits, apostrophes or punctuation, so a word counts as meant when its letters
/// (`Lexicon.fold`) match: "im" made "I'm" is kept.
///
/// It runs in an optimised build only, like RealTypoEval:
/// `swift test -c release -Xswiftc -enable-testing --filter NoisyTypingEval 2>&1 | grep '^noisy'`.
enum NoisyTyping {
  static let dir = ProcessInfo.processInfo.environment["V2T_NOISY_TYPING_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../build/noisy-typing").standardized

  static var available: Bool { FileManager.default.fileExists(atPath: dir.appending(path: "test.txt").path()) }

  static func file(_ name: String) throws -> String {
    let url = dir.appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path()) else {
      throw Lexicon.FormatError(description: "missing \(url.path()); run ios/tools/fetch_noisy_typing.py ios/build/noisy-typing")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  struct Tap: Equatable {
    /// Where the finger landed and where it lifted.
    var down: CGPoint, up: CGPoint
  }

  struct Sentence: Equatable {
    var source: String, keyboard: String, id: String
    var words: [String]
    /// One group of taps a word.
    var taps: [[Tap]]
  }

  /// keyboards.txt: each keyboard's letter keys, in its own coordinates.
  static func keyboards(_ text: String) throws -> [String: [Character: CGRect]] {
    var out: [String: [Character: CGRect]] = [:]
    for line in text.split(separator: "\n") {
      let p = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard p.count == 6, p[1].count == 1, let x = Double(p[2]), let y = Double(p[3]), let w = Double(p[4]), let h = Double(p[5]) else {
        throw Lexicon.FormatError(description: "keyboards.txt: \(line)")
      }
      out[String(p[0]), default: [:]][p[1].first!] = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
    }
    return out
  }

  /// dev.txt or test.txt: one sentence a line (see the script's docstring for the format).
  static func sentences(_ text: String) throws -> [Sentence] {
    try text.split(separator: "\n").map { line in
      let p = line.split(separator: "\t", omittingEmptySubsequences: false)
      func bad() -> Error { Lexicon.FormatError(description: "noisy typing: \(line.prefix(80))") }
      guard p.count == 5 else { throw bad() }
      let words = p[3].split(separator: " ").map(String.init)
      let taps: [[Tap]] = try p[4].split(separator: " ").map { group in
        try group.split(separator: ";").map { tap in
          let v = tap.split(separator: ",").compactMap { Double($0) }
          guard v.count == 4 else { throw bad() }
          return Tap(down: CGPoint(x: v[0], y: v[1]), up: CGPoint(x: v[2], y: v[3]))
        }
      }
      guard taps.count == words.count, !words.isEmpty else { throw bad() }
      return Sentence(source: String(p[0]), keyboard: String(p[1]), id: String(p[2]), words: words, taps: taps)
    }
  }

  /// The part of the data typed on a full-size keyboard that showed each key as it was hit.
  static func fullSizeWithPopups(_ source: String) -> Bool {
    source.hasPrefix("vt_exp2/") || source.hasPrefix("vt_exp1/") && source.hasSuffix("_feed") || source.hasPrefix("vt_exp3/") && source.hasSuffix("_normal")
  }

  /// A dataset keyboard's coordinates onto a v2t layout's: x and y each by the least-squares line through the
  /// pairs of letter centres.
  struct Mapping {
    var scaleX: Double, offsetX: Double, scaleY: Double, offsetY: Double

    init(from keys: [Character: CGRect], to layout: KeyboardLayout) {
      // in letter order: a sum in the dictionary's order differs in its last bits from run to run, and moves a
      // touch that lands exactly on a key's edge from one key to the next
      let pairs = keys.sorted { $0.key < $1.key }.compactMap { ch, r -> (CGPoint, CGPoint)? in
        Lexicon.fold(String(ch)).first.flatMap { layout.letterCenters[Int($0)] }.map { (CGPoint(x: r.midX, y: r.midY), $0) }
      }
      func fit(_ v: [(Double, Double)]) -> (Double, Double) {
        let n = Double(v.count), mx = v.map(\.0).reduce(0, +) / n, my = v.map(\.1).reduce(0, +) / n
        let sxy = v.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +), sxx = v.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        let slope = sxx > 0 ? sxy / sxx : 1
        return (slope, my - slope * mx)
      }
      (scaleX, offsetX) = fit(pairs.map { (Double($0.0.x), Double($0.1.x)) })
      (scaleY, offsetY) = fit(pairs.map { (Double($0.0.y), Double($0.1.y)) })
    }

    func callAsFunction(_ p: CGPoint) -> CGPoint {
      CGPoint(x: scaleX * Double(p.x) + offsetX, y: scaleY * Double(p.y) + offsetY)
    }
  }

  /// The letter a touch landing at `p` types on `layout`: its key's, or when that key is not a letter (shift,
  /// delete, the bottom row), the letter whose key centre is nearest. `onLetterKey` says which.
  static func letter(at p: CGPoint, in layout: KeyboardLayout) -> (letter: Character, onLetterKey: Bool) {
    if let k = layout.key(at: p), case .character(let c) = k.action, let ch = c.first, c.count == 1, ch.isLetter, ch.isASCII {
      return (ch, true)
    }
    var best: (Character, CGFloat) = ("a", .infinity)
    for b in UInt8(97)...UInt8(122) {
      guard let c = layout.letterCenters[Int(b)] else { continue }
      let d = hypot(c.x - p.x, c.y - p.y)
      if d < best.1 { best = (Character(UnicodeScalar(b)), d) }
    }
    return (best.0, false)
  }

  /// Which point each tap gives the suggester: where the finger really lifted, or the centre of the key it typed
  /// (the control: a touch model that reads the touches must do better than one told only the keys).
  enum Touches { case real, keyCentres }

  struct Result: Equatable {
    var name: String
    var touches = Touches.real
    var sentences = 0, words = 0, taps = 0, offLetterKeys = 0
    /// Words whose taps typed the meant letters: left so, or changed by autocorrect.
    var tappedRight = 0, kept = 0, changed = 0
    /// Words whose taps typed other letters: corrected to the meant word, to another, or left as typed.
    var tappedWrong = 0, fixed = 0, wrong = 0, untouched = 0
    /// Of the words tapped wrong, those whose meant word was in the bar's three slots before the space.
    var inBar = 0
    var changedExamples: [String] = [], wrongExamples: [String] = [], untouchedExamples: [String] = []

    static func == (a: Result, b: Result) -> Bool {
      [a.sentences, a.words, a.taps, a.offLetterKeys, a.tappedRight, a.kept, a.changed, a.tappedWrong, a.fixed, a.wrong, a.untouched, a.inBar]
        == [b.sentences, b.words, b.taps, b.offLetterKeys, b.tappedRight, b.kept, b.changed, b.tappedWrong, b.fixed, b.wrong, b.untouched, b.inBar]
    }
  }

  /// Each sentence typed in a fresh field, word by word with a space after each, with the words before it as
  /// context and sentence capitals as the keyboard sets them. Sentences are typed 50 at a time in parallel, each
  /// with its own engine and suggester; the counts do not depend on the order.
  static func row(_ name: String, _ sentences: [Sentence], keyboards: [String: [Character: CGRect]], lexicons: [Lexicon],
                  layout: KeyboardLayout, touches: Touches = .real, configure: (Suggester) -> Void = { _ in }) -> Result {
    let chunks = stride(from: 0, to: sentences.count, by: 50).map { Array(sentences[$0..<min($0 + 50, sentences.count)]) }
    var parts = [Result](repeating: Result(name: name), count: chunks.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
      let r = type(name, chunks[i], keyboards: keyboards, lexicons: lexicons, layout: layout, touches: touches, configure: configure)
      lock.lock()
      parts[i] = r
      lock.unlock()
    }
    var r = Result(name: name, touches: touches)
    for p in parts {
      r.sentences += p.sentences; r.words += p.words; r.taps += p.taps; r.offLetterKeys += p.offLetterKeys
      r.tappedRight += p.tappedRight; r.kept += p.kept; r.changed += p.changed
      r.tappedWrong += p.tappedWrong; r.fixed += p.fixed; r.wrong += p.wrong; r.untouched += p.untouched; r.inBar += p.inBar
      r.changedExamples += p.changedExamples.prefix(30 - r.changedExamples.count)
      r.wrongExamples += p.wrongExamples.prefix(30 - r.wrongExamples.count)
      r.untouchedExamples += p.untouchedExamples.prefix(30 - r.untouchedExamples.count)
    }
    return r
  }

  static func type(_ name: String, _ sentences: [Sentence], keyboards: [String: [Character: CGRect]], lexicons: [Lexicon],
                   layout: KeyboardLayout, touches: Touches, configure: (Suggester) -> Void) -> Result {
    var r = Result(name: name)
    var mappings: [String: Mapping] = [:]
    for sentence in sentences {
      guard let keys = keyboards[sentence.keyboard] else { continue }
      let map = mappings[sentence.keyboard] ?? Mapping(from: keys, to: layout)
      mappings[sentence.keyboard] = map
      r.sentences += 1
      let p = FakeProxy()
      let s = Suggester(lexicons: lexicons, layout: layout)
      configure(s)
      let e = TypingEngine(proxy: p, suggester: s)
      e.resync()
      var t: TimeInterval = 0
      for (word, taps) in zip(sentence.words, sentence.taps) {
        var letters = ""
        for tap in taps {
          let (ch, onKey) = letter(at: map(tap.down), in: layout)
          letters.append(ch)
          r.taps += 1
          if !onKey { r.offLetterKeys += 1 }
          let point = touches == .real ? map(tap.up) : Lexicon.fold(String(ch)).first.flatMap { layout.letterCenters[Int($0)] }
          t += 1
          e.character(String(ch), at: point, now: t)
        }
        let bar = e.suggestions().map { String(decoding: Lexicon.fold($0.word), as: UTF8.self) }
        t += 1
        e.space(now: t)
        let typed = String(p.text.dropLast().split(separator: " ").last ?? "")
        let got = String(decoding: Lexicon.fold(typed), as: UTF8.self)
        r.words += 1
        if letters == word {
          r.tappedRight += 1
          if got == word { r.kept += 1 } else {
            r.changed += 1
            if r.changedExamples.count < 30 { r.changedExamples.append("\(word)->\(typed)") }
          }
        } else {
          r.tappedWrong += 1
          if bar.contains(word) { r.inBar += 1 }
          if got == word { r.fixed += 1 } else if got == letters {
            r.untouched += 1
            if r.untouchedExamples.count < 30 { r.untouchedExamples.append("\(letters) (\(word))") }
          } else {
            r.wrong += 1
            if r.wrongExamples.count < 30 { r.wrongExamples.append("\(letters)->\(typed) (\(word))") }
          }
        }
      }
    }
    return r
  }

  /// Taps of words typed with one tap a letter, against the letter meant: inside its key on the dataset's
  /// keyboard, nearest its key there, and typing it on v2t's after the mapping.
  struct KeyHits { var taps = 0, insideKey = 0, nearestKey = 0, v2tKey = 0, offLetterKeys = 0 }

  static func keyHits(_ sentences: [Sentence], keys: [Character: CGRect], layout: KeyboardLayout) -> KeyHits {
    let map = Mapping(from: keys, to: layout)
    var h = KeyHits()
    for s in sentences {
      for (word, taps) in zip(s.words, s.taps) where taps.count == word.count {
        for (ch, tap) in zip(word, taps) {
          h.taps += 1
          if keys[ch]?.contains(tap.down) == true { h.insideKey += 1 }
          // ties (a touch midway between two centres) go to the earlier letter, not to the dictionary's order
          func d(_ r: CGRect) -> CGFloat { hypot(r.midX - tap.down.x, r.midY - tap.down.y) }
          let nearest = keys.min { d($0.value) != d($1.value) ? d($0.value) < d($1.value) : $0.key < $1.key }
          if nearest?.key == ch { h.nearestKey += 1 }
          let (v, onKey) = letter(at: map(tap.down), in: layout)
          if v == ch { h.v2tKey += 1 }
          if !onKey { h.offLetterKeys += 1 }
        }
      }
    }
    return h
  }

  static func pct(_ a: Int, _ n: Int) -> String { RealTypoEval.pct(a, n) }
  static func share(_ a: Int, _ n: Int) -> Double { 100 * Double(a) / Double(max(1, n)) }

  static func printHeader() {
    print("noisy | set | sentences | words | taps on a v2t key that is not a letter | tapped right | kept | changed by autocorrect | tapped wrong | fixed | wrong word | left as typed | meant word in bar (tapped wrong)")
  }

  static func printRow(_ r: Result, label: String = "noisy") {
    print("\(label) | \(r.name) | \(r.sentences) | \(r.words) | \(pct(r.offLetterKeys, r.taps)) | \(pct(r.tappedRight, r.words)) | \(pct(r.kept, r.tappedRight)) | \(pct(r.changed, r.tappedRight)) | \(pct(r.tappedWrong, r.words)) | \(pct(r.fixed, r.tappedWrong)) | \(pct(r.wrong, r.tappedWrong)) | \(pct(r.untouched, r.tappedWrong)) | \(pct(r.inBar, r.tappedWrong))")
  }
}

struct NoisyTypingEvalTests {
  static let enabled = RealTypoEval.optimised && NoisyTyping.available

  @Test(.enabled(if: enabled, "needs an optimised build (swift test -c release -Xswiftc -enable-testing --filter NoisyTypingEval) and ios/tools/fetch_noisy_typing.py ios/build/noisy-typing"))
  func realPhoneTaps() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let layout = KeyboardLayout(width: 402, language: .english)
    let keyboards = try NoisyTyping.keyboards(try NoisyTyping.file("keyboards.txt"))
    let dev = try NoisyTyping.sentences(try NoisyTyping.file("dev.txt")), test = try NoisyTyping.sentences(try NoisyTyping.file("test.txt"))

    // the mapping: where the taps land, on the dataset's keyboard and on v2t's
    print("noisy-keys | split | keyboard | taps (words with a tap a letter) | inside the meant key (dataset) | nearest the meant key (dataset) | type the meant key (v2t) | on a v2t key that is not a letter")
    var total: [String: NoisyTyping.KeyHits] = [:]
    for (split, rows) in [("dev", dev), ("test", test)] {
      for kb in keyboards.keys.sorted() {
        let h = NoisyTyping.keyHits(rows.filter { $0.keyboard == kb }, keys: keyboards[kb]!, layout: layout)
        guard h.taps > 0 else { continue }
        print("noisy-keys | \(split) | \(kb) | \(h.taps) | \(NoisyTyping.pct(h.insideKey, h.taps)) | \(NoisyTyping.pct(h.nearestKey, h.taps)) | \(NoisyTyping.pct(h.v2tKey, h.taps)) | \(NoisyTyping.pct(h.offLetterKeys, h.taps))")
        total[split, default: .init()].taps += h.taps
        total[split]!.insideKey += h.insideKey
        total[split]!.nearestKey += h.nearestKey
        total[split]!.v2tKey += h.v2tKey
        total[split]!.offLetterKeys += h.offLetterKeys
      }
      let h = total[split]!
      print("noisy-keys | \(split) | all | \(h.taps) | \(NoisyTyping.pct(h.insideKey, h.taps)) | \(NoisyTyping.pct(h.nearestKey, h.taps)) | \(NoisyTyping.pct(h.v2tKey, h.taps)) | \(NoisyTyping.pct(h.offLetterKeys, h.taps))")
      // the mapping keeps which key is nearest: v2t types the key nearest on the dataset's keyboard
      #expect(abs(NoisyTyping.share(h.v2tKey, h.taps) - NoisyTyping.share(h.nearestKey, h.taps)) < 1, "\(split): v2t keys against the dataset's nearest keys")
    }

    let popups = NoisyTyping.fullSizeWithPopups
    let rows = [
      NoisyTyping.row("dev, all", dev, keyboards: keyboards, lexicons: [en], layout: layout),
      NoisyTyping.row("dev, full-size, key popups", dev.filter { popups($0.source) }, keyboards: keyboards, lexicons: [en], layout: layout),
      NoisyTyping.row("test, all", test, keyboards: keyboards, lexicons: [en], layout: layout),
      NoisyTyping.row("test, full-size, key popups", test.filter { popups($0.source) }, keyboards: keyboards, lexicons: [en], layout: layout),
      NoisyTyping.row("test, all, EN+ES on", test, keyboards: keyboards, lexicons: [en, es], layout: layout),
      // the control: the same letters, each tap at the centre of the key it typed
      NoisyTyping.row("dev, all, taps at key centres", dev, keyboards: keyboards, lexicons: [en], layout: layout, touches: .keyCentres),
      NoisyTyping.row("test, all, taps at key centres", test, keyboards: keyboards, lexicons: [en], layout: layout, touches: .keyCentres),
    ]
    NoisyTyping.printHeader()
    for r in rows {
      NoisyTyping.printRow(r)
      print("noisy-changed | \(r.name) | \(r.changedExamples)")
      print("noisy-wrong | \(r.name) | \(r.wrongExamples)")
      print("noisy-untouched | \(r.name) | \(r.untouchedExamples)")
    }
    // the control: real touches carry more than the keys they typed, so they must fix more and make fewer wrong
    // words; the other way round would say the mapping puts the touches in the wrong place
    #expect(rows[0].fixed > rows[5].fixed && rows[0].wrong < rows[5].wrong, "dev: real touches against key centres")
    #expect(rows[2].fixed > rows[6].fixed && rows[2].wrong < rows[6].wrong, "test: real touches against key centres")
    // floors a couple of points under the measured values (2026-11-12), so a regression fails
    let share = NoisyTyping.share
    #expect(share(rows[0].fixed, rows[0].tappedWrong) >= 74, "dev: mistapped words fixed")
    #expect(share(rows[0].wrong, rows[0].tappedWrong) <= 9.5, "dev: mistapped words made a wrong word")
    #expect(share(rows[2].fixed, rows[2].tappedWrong) >= 69, "test: mistapped words fixed")
    #expect(share(rows[2].wrong, rows[2].tappedWrong) <= 12, "test: mistapped words made a wrong word")
    #expect(share(rows[2].inBar, rows[2].tappedWrong) >= 82.5, "test: meant word in the bar")
    #expect(share(rows[3].fixed, rows[3].tappedWrong) >= 69, "test, full-size: mistapped words fixed")
    #expect(share(rows[3].wrong, rows[3].tappedWrong) <= 10, "test, full-size: mistapped words made a wrong word")
    for r in rows where r.touches == .real {
      #expect(share(r.changed, r.tappedRight) <= 0.5, "\(r.name): correctly tapped words changed")
    }
    // a hand-checked sentence: eyesfree_exp1's dev mobile7, "this will be hard", whose taps land nearest the
    // meant keys on the iPhone 4 layout (checked against keyboard_iphone4.txt by hand), types as written
    let hand = try #require(dev.first { $0.source == "eyesfree_exp1/d1_sighted" && $0.id == "mobile7" })
    let handRow = NoisyTyping.row("hand", [hand], keyboards: keyboards, lexicons: [en], layout: layout)
    #expect(hand.words == ["this", "will", "be", "hard"])
    #expect(handRow.tappedRight == 4 && handRow.kept == 4, "\(handRow)")
  }
}

/// NoisyTypingEval's development rows under other weights, off by default; the settings are RealTypoTuning's:
///
///     V2T_TYPO_TUNE='base;wide:std=0.5' swift test -c release -Xswiftc -enable-testing --filter NoisyTypingTuning
///
/// `V2T_NOISY_SPLIT=test` types the test split instead.
struct NoisyTypingTuning {
  static let env = ProcessInfo.processInfo.environment

  @Test(.enabled(if: env["V2T_TYPO_TUNE"] != nil && NoisyTyping.available))
  func table() throws {
    let en = try Fixtures.english.get()
    let layout = KeyboardLayout(width: 402, language: .english)
    let keyboards = try NoisyTyping.keyboards(try NoisyTyping.file("keyboards.txt"))
    let split = Self.env["V2T_NOISY_SPLIT"] ?? "dev"
    let sentences = try NoisyTyping.sentences(try NoisyTyping.file("\(split).txt"))
    let popups = sentences.filter { NoisyTyping.fullSizeWithPopups($0.source) }
    NoisyTyping.printHeader()
    for (name, apply) in RealTypoTuning.settings(Self.env["V2T_TYPO_TUNE"]!) {
      NoisyTyping.printRow(NoisyTyping.row("\(name) | \(split), all", sentences, keyboards: keyboards, lexicons: [en], layout: layout, configure: apply), label: "noisytune")
      NoisyTyping.printRow(NoisyTyping.row("\(name) | \(split), full-size, key popups", popups, keyboards: keyboards, lexicons: [en], layout: layout, configure: apply), label: "noisytune")
    }
  }
}

/// The parsing, mapping and counting above, on a made-up keyboard and made-up taps: no dataset rows.
struct NoisyTypingTests {
  let layout = KeyboardLayout(width: 402, language: .english)

  /// A made-up keyboard staggered as both real ones: keys 30 by 50 at a 32 by 60 pitch, the middle row half a key
  /// in and the bottom row one and a half.
  static let keyboardText: String = {
    var lines: [String] = []
    for (row, letters) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
      for (i, ch) in letters.enumerated() {
        lines.append("toy\t\(ch)\t\(16 + 32 * i + [0, 16, 48][row])\t\(25 + 60 * row)\t30\t50")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }()

  func toyCentre(_ ch: Character) throws -> CGPoint {
    let r = try #require(try NoisyTyping.keyboards(Self.keyboardText)["toy"]?[ch])
    return CGPoint(x: r.midX, y: r.midY)
  }

  @Test func readsKeyboards() throws {
    let kb = try NoisyTyping.keyboards(Self.keyboardText)
    #expect(kb.keys.sorted() == ["toy"])
    #expect(kb["toy"]?.count == 26)
    #expect(kb["toy"]?["g"] == CGRect(x: 145, y: 60, width: 30, height: 50))
  }

  @Test func readsSentences() throws {
    let text = "study/p1\ttoy\tmobile1\tto be\t1,2,3,4;5,6,7,8 9.5,10,11,12\n"
    #expect(try NoisyTyping.sentences(text) == [NoisyTyping.Sentence(
      source: "study/p1", keyboard: "toy", id: "mobile1", words: ["to", "be"],
      taps: [[.init(down: CGPoint(x: 1, y: 2), up: CGPoint(x: 3, y: 4)), .init(down: CGPoint(x: 5, y: 6), up: CGPoint(x: 7, y: 8))],
             [.init(down: CGPoint(x: 9.5, y: 10), up: CGPoint(x: 11, y: 12))]])])
  }

  @Test func rejectsASentenceWhoseTapGroupsAreNotItsWords() {
    #expect(throws: (any Error).self) { try NoisyTyping.sentences("study/p1\ttoy\tmobile1\tto be\t1,2,3,4\n") }
  }

  @Test func mapsKeyCentresOntoV2TKeyCentres() throws {
    let map = NoisyTyping.Mapping(from: try NoisyTyping.keyboards(Self.keyboardText)["toy"]!, to: layout)
    for ch in "qwertyuiopasdfghjklzxcvbnm" {
      let got = map(try toyCentre(ch)), want = layout.letterCenters[Int(ch.asciiValue!)]!
      #expect(hypot(got.x - want.x, got.y - want.y) < 0.01, "\(ch)")
    }
  }

  @Test func keepsAnOffsetInKeyPitches() throws {
    let map = NoisyTyping.Mapping(from: try NoisyTyping.keyboards(Self.keyboardText)["toy"]!, to: layout)
    // a quarter of a pitch right of g and a quarter of a row below it
    let g = try toyCentre("g"), got = map(CGPoint(x: g.x + 8, y: g.y + 15)), v = layout.letterCenters[Int(Character("g").asciiValue!)]!
    let pitchX = Double(layout.unitWidth + layout.metrics.gap), pitchY = Double(layout.metrics.rowPitch)
    #expect(abs(Double(got.x - v.x) - pitchX / 4) < 0.01)
    #expect(abs(Double(got.y - v.y) - pitchY / 4) < 0.01)
  }

  @Test func aTouchOnAKeyThatIsNotALetterTypesTheNearestLetter() throws {
    let shift = try #require(layout.keys.first { $0.action == .shift })
    let onShift = NoisyTyping.letter(at: shift.center, in: layout)
    #expect(onShift.letter == "z" && !onShift.onLetterKey)
    let onG = NoisyTyping.letter(at: layout.letterCenters[Int(Character("g").asciiValue!)]!, in: layout)
    #expect(onG.letter == "g" && onG.onLetterKey)
  }

  /// One sentence tapped at the made-up keyboard's centres, "the" tapped "thw": every count of the row.
  @Test func countsWhatAutocorrectDidWithEachWord() throws {
    let kb = try NoisyTyping.keyboards(Self.keyboardText)
    func taps(_ letters: String) throws -> String {
      try letters.map { ch in let c = try toyCentre(ch); return "\(c.x),\(c.y),\(c.x),\(c.y)" }.joined(separator: ";")
    }
    let line = "s/p1\ttoy\tm1\ti think the plan works\t\(try taps("i")) \(try taps("think")) \(try taps("thw")) \(try taps("plan")) \(try taps("works"))\n"
    let r = NoisyTyping.row("toy", try NoisyTyping.sentences(line), keyboards: kb, lexicons: [try Fixtures.english.get()], layout: layout)
    var want = NoisyTyping.Result(name: "toy")
    (want.sentences, want.words, want.taps, want.offLetterKeys) = (1, 5, 18, 0)
    (want.tappedRight, want.kept, want.changed) = (4, 4, 0)
    (want.tappedWrong, want.fixed, want.wrong, want.untouched) = (1, 1, 0, 0)
    want.inBar = 1
    #expect(r == want, "\(r)")
  }
}
