import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Types a keyboard debug log (#162) again through the engine as it is now, so a change to autocorrect or the
/// bar is measured on what a person really typed, touch points included, rather than on key centres.
///
///     V2T_KB_LOG=~/Downloads/keyboard.jsonl swift test --filter LogReplayEval 2>&1 | grep '^replay'
///
/// Each finished word prints one line: the letters typed, the word before it, what the build that wrote the log
/// did (`logged`), what this build does (`now`), and the bar. `replay-summary` counts them. A word whose `logged`
/// and `now` differ is a decision the change moved; the log's own `autocorrect` lines are the control that the
/// replay follows the keyboard (an unchanged build must print `moved 0`).
///
/// What the log leaves out limits it: text the host put in the field and dictated text are recorded by length
/// only. The replay puts that many blocks there, so nothing before them reads as a word, and leaves out the
/// first word typed after them (`not replayed`): it may have joined letters the log does not hold.
enum LogReplayEval {
  static let path = ProcessInfo.processInfo.environment["V2T_KB_LOG"].map { NSString(string: $0).expandingTildeInPath }

  struct Word: Equatable {
    var typed: String, previous: String?, logged: String?, now: String?, bar: [String]
  }

  struct Outcome {
    var words: [Word] = []
    /// Key presses after which a space would have put in a word the bar did not show.
    var hiddenPending = 0
    /// Key presses that left a word in progress.
    var composingKeys = 0
    /// Word boundaries after which the bar was empty.
    var emptyBars = 0, boundaries = 0
    /// Words typed straight after text the log does not hold.
    var notReplayed = 0
  }

  /// Runs every keyboard session of the log (one per `appear` line) through a fresh engine.
  static func replay(_ lines: [String], lexicons: [String: Lexicon]) -> Outcome {
    var out = Outcome()
    var engine: TypingEngine?, proxy = FakeProxy()
    // the word a boundary key ended, waiting for the log's own autocorrect line (which follows the key)
    var open: Int?
    // the word in progress may join letters the log does not hold
    var unknownStart = false
    func boundary(_ e: TypingEngine, _ body: () -> Void) {
      let typed = e.literal
      guard !typed.isEmpty else { body(); return }
      if unknownStart {
        unknownStart = false
        out.notReplayed += 1
        body()
        return
      }
      let word = Word(typed: typed, previous: e.context.previous, logged: nil, now: e.pendingAutocorrection, bar: e.suggestions().map(\.word))
      body()
      out.words.append(word)
      open = out.words.count - 1
      out.boundaries += 1
      if e.suggestions().isEmpty { out.emptyBars += 1 }
    }
    for line in lines {
      guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let name = o["e"] as? String else { continue }
      let now = (o["t"] as? Double ?? 0) / 1000
      if name == "appear" {
        let languages = (o["languages"] as? [String] ?? ["en"]).compactMap { lexicons[$0] }
        let layout = KeyboardLayout(width: CGFloat(o["width"] as? Double ?? 402), language: KeyboardLanguage(rawValue: o["layout"] as? String ?? "en") ?? .english)
        proxy = FakeProxy()
        engine = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: languages, layout: layout))
        open = nil
        unknownStart = false
        continue
      }
      guard let e = engine else { continue }
      switch name {
      case "key":
        guard let text = o["text"] as? String, o["search"] as? Bool != true else { continue }
        let p = (o["p"] as? [Double]).map { CGPoint(x: $0[0], y: $0[1]) }
        let ends = !(text.first.map { $0.isLetter || $0.isNumber || TypingEngine.isApostrophe($0) && !e.composing.isEmpty } ?? false)
        if ends { boundary(e) { e.character(text, at: p, now: now) } } else {
          e.character(text, at: p, now: now)
          open = nil
          out.composingKeys += 1
          if let pending = e.pendingAutocorrection, !e.suggestions().contains(where: { $0.word == pending }) { out.hiddenPending += 1 }
        }
      case "act":
        switch o["a"] as? String {
        case "space": boundary(e) { e.space(now: now) }
        case "returnKey": boundary(e) { e.returnKey() }
        case "delete": e.delete(); open = nil
        case "deleteWord": e.deleteWord(); open = nil
        default: break
        }
      case "autocorrect":
        if let i = open, let from = o["from"] as? String, from == out.words[i].typed { out.words[i].logged = o["to"] as? String }
      case "pick":
        if let w = o["word"] as? String { e.pick(w) }
        open = nil
      case "emoji":
        if let s = o["emoji"] as? String { e.emoji(s) }
        open = nil
      case "host", "dictation":
        // the text is not in the log, only its length
        let chars = o["chars"] as? Int ?? 0
        if name == "host" { proxy.text = String(repeating: "█", count: chars) } else { e.insertFinished(String(repeating: "█", count: chars)) }
        e.resync()
        unknownStart = chars > 0
        open = nil
      default: break
      }
    }
    return out
  }

  @Test(.enabled(if: path != nil)) static func replaysTheLog() throws {
    let lines = try String(contentsOfFile: path!, encoding: .utf8).split(separator: "\n").map(String.init)
    let out = replay(lines, lexicons: ["en": try Fixtures.english.get(), "es": try Fixtures.spanish.get()])
    for w in out.words {
      let mark = w.logged == w.now ? " " : "*"
      print("replay \(mark) \(w.typed) after=\(w.previous ?? "-") logged=\(w.logged ?? "-") now=\(w.now ?? "-") bar=\(w.bar)")
    }
    let moved = out.words.filter { $0.logged != $0.now }.count
    print("replay-summary words \(out.words.count), autocorrected logged \(out.words.filter { $0.logged != nil }.count) now \(out.words.filter { $0.now != nil }.count), moved \(moved)")
    print("replay-summary key presses in a word \(out.composingKeys), with a pending correction the bar did not show \(out.hiddenPending)")
    print("replay-summary word boundaries \(out.boundaries), left the bar empty \(out.emptyBars); words not replayed \(out.notReplayed)")
    #expect(!out.words.isEmpty)
  }
}
