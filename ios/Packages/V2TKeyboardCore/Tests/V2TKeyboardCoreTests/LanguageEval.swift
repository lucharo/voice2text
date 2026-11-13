import Foundation
import Testing
@testable import V2TKeyboardCore

/// Which language the bar writes in, on more sentences than QualityEval's ten a language: RealTypoEval's 1,043
/// Tatoeba sentences a language (lowercase, punctuation taken off) and NoisyTypingEval's Enron sentences, typed
/// with English and Spanish on, after each word and a space (next word) and after the next word's first letter.
/// The Tatoeba sentences also fed the next-word statistics, so their rates run high; the rows are for comparing
/// settings, and a Spanish sentence must stay Spanish.
///
///     swift test -c release -Xswiftc -enable-testing --filter LanguageEval 2>&1 | grep '^language'
///
/// `V2T_TUNE` (QualityTuning's settings) prints the rows under each setting.
struct LanguageEval {
  static func clean(_ s: String) -> String {
    String(s.lowercased().map { (c: Character) -> Character in c.isLetter || c == "'" ? c : " " }).split(separator: " ").joined(separator: " ")
  }

  @Test(.enabled(if: RealTypoEval.optimised, "slow in a debug build"))
  func barLanguage() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let layout = KeyboardLayout(width: 402, language: .english)
    let enText = try RealTypoEval.sentences("en").map(Self.clean), esText = try RealTypoEval.sentences("es").map(Self.clean)
    var enron: [String] = []
    if NoisyTyping.available { enron = try NoisyTyping.sentences(try NoisyTyping.file("dev.txt")).map { $0.words.joined(separator: " ") } }
    let configs = ProcessInfo.processInfo.environment["V2T_TUNE"].map(QualityTuning.configs) ?? [("now", QualityEval.Config())]
    for (name, config) in configs {
      for (set, sentences) in [("EN Tatoeba", enText), ("ES Tatoeba", esText), ("EN Enron dev", enron)] where !sentences.isEmpty {
        for letters in [0, 1] {
          let r = QualityEval.sentenceBarRow("\(set), \(letters == 0 ? "next word" : "after 1 letter")", sentences: sentences, letters: letters,
                                             layout: layout, lexicons: [en, es], config: config)
          print("language | \(name) | \(r.name) | \(r.total) | \(QualityEval.pct(r.hit1, r.total)) | \(QualityEval.pct(r.hit4, r.total))")
        }
      }
    }
  }
}
