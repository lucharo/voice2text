import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// QualityEval's table under other weights, off by default:
///
///     V2T_TUNE='legacy:fw=5,pn=0,ac=0,other=0,sb=0,sf=8,sbg=0,sac=0;w10:fw=10' \
///       swift test -c release -Xswiftc -enable-testing --filter QualityTuning
///
/// Keys: fw/pn/ac the swipe frequency weight and proper-noun and acronym penalties, other the prior of a
/// language other than the layout's, sb/sbg the swipe and suggestion bigram weights, sf the suggestion
/// frequency weight, sac the suggestion acronym penalty. `V2T_LEXICON_DIR` points at other lexicons.
struct QualityTuning {
  static let env = ProcessInfo.processInfo.environment

  static func configs(_ spec: String) -> [(String, QualityEval.Config)] {
    spec.split(separator: ";").map { item in
      let parts = item.split(separator: ":", maxSplits: 1)
      var c = QualityEval.Config()
      for kv in parts.count > 1 ? parts[1].split(separator: ",") : [] {
        let p = kv.split(separator: "="), v = Double(p[1])!
        switch p[0] {
        case "fw": c.frequencyWeight = v
        case "pn": c.properNounPenalty = v
        case "ac": c.acronymPenalty = v
        case "other": c.otherLanguage = v
        case "cap": c.languageCap = v
        case "sb": c.swipeBigram = v
        case "sf": c.suggestFrequency = v
        case "sbg": c.suggestBigram = v
        case "sac": c.suggestAcronym = v
        case "am": c.alternativeMargin = v
        case "mcp": c.minCompletionPrefix = v
        default: Issue.record("unknown key \(p[0])")
        }
      }
      return (String(parts[0]), c)
    }
  }

  @Test(.enabled(if: env["V2T_TUNE"] != nil))
  func table() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    for (name, config) in Self.configs(Self.env["V2T_TUNE"]!) {
      let rows = QualityEval.table(en, es, config: config)
      QualityEval.printTable(rows, label: "tune \(name)")
      if Self.env["V2T_TUNE_MISSES"] != nil { for r in rows { print("tune-misses \(name) | \(r.name) | \(r.misses.prefix(20))") } }
    }
  }
}
