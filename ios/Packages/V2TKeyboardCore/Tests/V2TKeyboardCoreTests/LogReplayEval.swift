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
/// The replay follows the field's traits (autocorrect off, capitals), keys, space, return, tab, delete, shift,
/// caps lock, bar picks, emoji and the words swipes typed. What the log leaves out limits it: text the host put
/// in the field, dictated text and anything in a field a dictation went into are recorded by length only, and a
/// cursor move says how far, not past what. The replay puts blocks there, so nothing before them reads as a
/// word, and leaves out the first word typed after them (`not replayed`): it may have joined letters the log
/// does not hold. A correction the log records without its words is marked `?` and not compared. Keys pressed in
/// emoji search are skipped; logs written before `act` lines carried `search` do not mark search's space, delete
/// and return, so a search in one of those reads as typing.
enum LogReplayEval {
  static let path = ProcessInfo.processInfo.environment["V2T_KB_LOG"].map { NSString(string: $0).expandingTildeInPath }

  struct Word: Equatable {
    var typed: String, previous: String?, logged: String?, now: String?, bar: [String]
    /// The log says a correction was made here but not to what (a field a dictation went into): not compared.
    var loggedUnknown = false
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
    // a correction the log names before the line that ends its word here (a swipe commits the word, then is logged)
    var early: (from: String, to: String)?
    func boundary(_ e: TypingEngine, _ body: () -> Void) {
      let typed = e.literal
      guard !typed.isEmpty else { body(); return }
      if unknownStart {
        unknownStart = false
        out.notReplayed += 1
        body()
        return
      }
      let previous = e.context.previous, bar = e.suggestions().map(\.word)
      // what the engine does at this boundary, not what a space would do: "@" and "_" keep the letters as typed
      var applied: String?
      e.onEvent = { if case .autocorrected(_, let replacement) = $0 { applied = replacement } }
      body()
      e.onEvent = nil
      out.words.append(Word(typed: typed, previous: previous, logged: early?.from == typed ? early?.to : nil, now: applied, bar: bar))
      early = nil
      open = out.words.count - 1
      out.boundaries += 1
      if e.suggestions().isEmpty { out.emptyBars += 1 }
    }
    /// Text the log does not hold is before the cursor now: `blocks` characters of it.
    func unknown(_ e: TypingEngine, blocks: Int) {
      proxy.text += String(repeating: "█", count: blocks)
      e.resync()
      unknownStart = blocks > 0
      open = nil
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
        early = nil
        continue
      }
      guard let e = engine else { continue }
      switch name {
      case "field":
        var traits = FieldTraits(autocorrect: o["autocorrect"] as? Bool ?? true)
        switch o["capitalization"] as? String {
        case "none": traits.capitalization = .none
        case "words": traits.capitalization = .words
        case "all": traits.capitalization = .all
        default: traits.capitalization = .sentences
        }
        e.traits = traits
        e.resync()
      case "key":
        guard let text = o["text"] as? String, o["search"] as? Bool != true else { continue }
        let p = (o["p"] as? [Double]).map { CGPoint(x: $0[0], y: $0[1]) }
        let ends = !(text.first.map { $0.isLetter || $0.isNumber || TypingEngine.isApostrophe($0) && !e.composing.isEmpty } ?? false)
        if ends { boundary(e) { e.character(text, at: p, now: now) } } else {
          e.character(text, at: p, now: now)
          open = nil
          early = nil
          out.composingKeys += 1
          if let pending = e.pendingAutocorrection, !e.suggestions().contains(where: { $0.word == pending }) { out.hiddenPending += 1 }
        }
      case "act":
        // keys pressed while emoji search is open go to its field, not the document
        if o["search"] as? Bool == true { break }
        switch o["a"] as? String {
        case "space": boundary(e) { e.space(now: now) }
        case "returnKey": boundary(e) { e.returnKey() }
        case "tab": boundary(e) { e.character("\t") }
        case "delete": e.delete(); open = nil
        case "deleteWord": e.deleteWord(); open = nil
        case "shift": e.shiftTap(now: now)
        case "capsLock": e.capsLockTap()
        default: break
        }
      case "autocorrect":
        guard let from = o["from"] as? String, let to = o["to"] as? String else {
          if let i = open { out.words[i].loggedUnknown = true }  // by name only in a redacted field
          break
        }
        if let i = open, from == out.words[i].typed { out.words[i].logged = to } else { early = (from, to) }
      case "swiped":
        // the word the swipe typed, after ending the word in progress as the engine does
        if let w = o["word"] as? String { boundary(e) { e.swipe([w] + (o["alternatives"] as? [String] ?? [])) } } else { unknown(e, blocks: 1) }
        open = nil
      case "pick":
        if let w = o["word"] as? String { e.pick(w); open = nil } else { unknown(e, blocks: 1) }
      case "cursor":
        // left: the characters passed are after the cursor now; right: the ones passed are not in the log
        let by = o["by"] as? Int ?? 0
        if by < 0 { proxy.text = String(proxy.text.dropLast(-by)) }
        unknown(e, blocks: max(1, by))
      case "emoji":
        if let s = o["emoji"] as? String { e.emoji(s) }
        open = nil
      case "host", "dictation":
        // the text is not in the log, only its length
        let chars = o["chars"] as? Int ?? 0
        if name == "host" { proxy.text = "" } else { e.insertFinished("") }
        unknown(e, blocks: chars)
      default: break
      }
    }
    return out
  }

  @Test(.enabled(if: path != nil)) static func replaysTheLog() throws {
    let lines = try String(contentsOfFile: path!, encoding: .utf8).split(separator: "\n").map(String.init)
    let out = replay(lines, lexicons: ["en": try Fixtures.english.get(), "es": try Fixtures.spanish.get()])
    let known = out.words.filter { !$0.loggedUnknown }
    for w in out.words {
      let mark = w.loggedUnknown ? "?" : w.logged == w.now ? " " : "*"
      print("replay \(mark) \(w.typed) after=\(w.previous ?? "-") logged=\(w.loggedUnknown ? "?" : w.logged ?? "-") now=\(w.now ?? "-") bar=\(w.bar)")
    }
    let moved = known.filter { $0.logged != $0.now }.count
    print("replay-summary words \(out.words.count), autocorrected logged \(known.filter { $0.logged != nil }.count) now \(known.filter { $0.now != nil }.count), moved \(moved); corrected to a word the log does not name \(out.words.count - known.count)")
    print("replay-summary key presses in a word \(out.composingKeys), with a pending correction the bar did not show \(out.hiddenPending)")
    print("replay-summary word boundaries \(out.boundaries), left the bar empty \(out.emptyBars); words not replayed \(out.notReplayed)")
    #expect(!out.words.isEmpty)
  }
}
