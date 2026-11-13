import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Two words typed without the space between them ("needsme" for "needs me") against a compound the word lists
/// lack ("changelog"): the first should come back as the two words, the second stay as typed (or, at worst, be
/// cut into its two words), and neither become a third word ("changeling").
///
/// - Space left out: every pair of neighbouring words of NoisyTypingEval's Enron sentences (development and test,
///   each sentence once), and of RealTypoEval's Tatoeba sentences, typed as one at the key centres after the
///   words before them. The Tatoeba sentences also fed the next-word statistics the rule reads, so the Enron row
///   is the fair one.
/// - Compounds: the words of Webster's Second International (1934, public domain; `/usr/share/dict/web2` on a
///   Mac) the English list lacks that are two English words of three letters or more each ("bookrack":
///   book, rack), typed at the key centres after "I think the ".
///
///     swift test -c release -Xswiftc -enable-testing --filter MissingSpaceEval 2>&1 | grep '^missingspace'
///
/// `V2T_TYPO_TUNE` (RealTypoTuning's settings) prints the rows under each setting instead.
enum MissingSpaceEval {
  static let web2 = URL(fileURLWithPath: "/usr/share/dict/web2")

  struct Row {
    var name: String
    var total = 0, split = 0, isWord = 0, kept = 0, other = 0
    var examples: [String] = []
  }

  static func words(_ sentence: String) -> [String] {
    sentence.split(separator: " ").map { String($0.filter { (c: Character) in c.isLetter || c == "'" }) }.filter { !$0.isEmpty }
  }

  /// Each pair of neighbouring words typed as one, in lowercase, after the words before it.
  static func spaceRow(_ name: String, _ sentences: [String], _ s: Suggester) -> Row {
    var r = Row(name: name)
    for sentence in Set(sentences).sorted() {
      let w = words(sentence.lowercased())
      for i in w.indices.dropLast() where !w[i].contains("'") && !w[i + 1].contains("'") {
        let joined = w[i] + w[i + 1], want = w[i] + " " + w[i + 1]
        r.total += 1
        if s.isWord(joined) { r.isWord += 1; continue }
        let context = TypingContext(before: w[..<i].joined(separator: " ") + (i > 0 ? " " : ""))
        let got = s.autocorrection(for: RealTypoEval.taps(joined, s.layout), context: context)
        if got?.lowercased() == want { r.split += 1 } else if got == nil { r.kept += 1 } else {
          r.other += 1
          if r.examples.count < 25 { r.examples.append("\(joined)->\(got!) (\(want))") }
        }
      }
    }
    return r
  }

  /// The web2 words the English list lacks that are two English words of three letters or more.
  static func compounds(_ en: Lexicon) throws -> [String] {
    let s = Suggester(lexicons: [en], layout: KeyboardLayout(width: 402, language: .english))
    return try String(contentsOf: web2, encoding: .utf8).split(separator: "\n").map(String.init).filter { w in
      w.count >= 6 && w.allSatisfy { $0.isASCII && $0.isLowercase } && en.entry(of: w) == nil && !s.twoWords(w, minPart: 3).isEmpty
    }
  }

  static func compoundRow(_ name: String, _ words: [String], _ s: Suggester) -> Row {
    var r = Row(name: name)
    let context = TypingContext(before: "I think the ")
    for w in words {
      r.total += 1
      let got = s.autocorrection(for: RealTypoEval.taps(w, s.layout), context: context)
      if got == nil { r.kept += 1 } else if got!.contains(" "), got!.replacingOccurrences(of: " ", with: "").lowercased() == w { r.split += 1 } else {
        r.other += 1
        if r.examples.count < 25 { r.examples.append("\(w)->\(got!)") }
      }
    }
    return r
  }

  static func table(_ en: Lexicon, _ es: Lexicon, configure: (Suggester) -> Void, label: String) throws {
    let enLayout = KeyboardLayout(width: 402, language: .english), esLayout = KeyboardLayout(width: 402, language: .spanish)
    func make(_ lex: [Lexicon], _ layout: KeyboardLayout) -> Suggester { let s = Suggester(lexicons: lex, layout: layout); configure(s); return s }
    var enron: [String] = []
    if NoisyTyping.available {
      for split in ["dev", "test"] { enron += try NoisyTyping.sentences(try NoisyTyping.file("\(split).txt")).map { $0.words.joined(separator: " ") } }
    }
    let rows = [
      spaceRow("space left out, Enron sentences, EN", enron, make([en], enLayout)),
      spaceRow("space left out, Enron sentences, EN+ES", enron, make([en, es], enLayout)),
      spaceRow("space left out, Tatoeba EN sentences, EN+ES", try RealTypoEval.sentences("en"), make([en, es], enLayout)),
      spaceRow("space left out, Tatoeba ES sentences, ES", try RealTypoEval.sentences("es"), make([es], esLayout)),
    ]
    print("\(label) | set | pairs | split back | the pair is a word | left as typed | another word")
    for r in rows {
      print("\(label) | \(r.name) | \(r.total) | \(RealTypoEval.pct(r.split, r.total - r.isWord)) | \(r.isWord) | \(RealTypoEval.pct(r.kept, r.total - r.isWord)) | \(RealTypoEval.pct(r.other, r.total - r.isWord))")
      print("\(label)-other | \(r.name) | \(r.examples)")
    }
    guard FileManager.default.fileExists(atPath: web2.path()) else { print("\(label) | no \(web2.path()): compounds not measured"); return }
    let list = try compounds(en)
    print("\(label) | set | compounds | left as typed | cut into its two words | another word")
    for r in [compoundRow("web2 compounds the list lacks, EN", list, make([en], enLayout)),
              compoundRow("web2 compounds the list lacks, EN+ES", list, make([en, es], enLayout))] {
      print("\(label) | \(r.name) | \(r.total) | \(RealTypoEval.pct(r.kept, r.total)) | \(RealTypoEval.pct(r.split, r.total)) | \(RealTypoEval.pct(r.other, r.total))")
      print("\(label)-other | \(r.name) | \(r.examples)")
    }
  }
}

struct MissingSpaceEvalTests {
  @Test(.enabled(if: RealTypoEval.optimised, "slow in a debug build: run swift test -c release -Xswiftc -enable-testing --filter MissingSpaceEval"))
  func spaceLeftOutAndCompounds() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    if let spec = RealTypoTuning.spec {
      for (name, apply) in RealTypoTuning.settings(spec) { try MissingSpaceEval.table(en, es, configure: apply, label: "missingspace \(name)") }
    } else {
      try MissingSpaceEval.table(en, es, configure: { _ in }, label: "missingspace")
    }
  }
}
