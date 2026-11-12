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
/// does not hold. Words kept in an earlier session of the log stay kept in later ones; words kept before the log
/// began are unknown. An iPad's sessions are left out: its layout depends on an orientation the log does not
/// record. A correction the log records without its words is marked `?` and not compared. Keys pressed in
/// emoji search are skipped; logs written before `act` lines carried `search` do not mark search's space, delete
/// and return, so a search in one of those reads as typing.
///
/// A log with typing exercise lines (an Export from the app) also prints `replay-exercise` lines: for each word
/// of an exercise sentence, what this engine made of the word typed while the sentence was on screen
/// (`scoreExercises`), then a `replay-exercise-summary`.
enum LogReplayEval {
  static let path = ProcessInfo.processInfo.environment["V2T_KB_LOG"].map { NSString(string: $0).expandingTildeInPath }

  struct Word: Equatable {
    var typed: String, previous: String?, logged: String?, now: String?, bar: [String]
    /// The log says a correction was made here but not to what (a field a dictation went into): not compared.
    var loggedUnknown = false
    /// Milliseconds of uptime of the key that ended the word, and whether delete was pressed since the word
    /// before it ended: for lining words up with a typing exercise's sentence.
    var t: Double = 0
    var deleted = false
    /// The clock time at uptime 0 for the keyboard session it was typed in (its `appear` line's wall less its
    /// uptime): one per boot of the phone, since uptime starts again with each.
    var boot: Double? = nil
  }

  /// Exercises and keyboard sessions this many seconds apart in their boot anchors are the same boot (the
  /// uptime clock and the wall clock drift apart a little; kb_log_report.py's WALL_SLACK_S).
  static let bootSlack: Double = 120

  /// The clock time at uptime 0 for a line with `t` (uptime ms) and `wall` (ISO time).
  static func bootAnchor(_ o: [String: Any]) -> Double? {
    guard let t = o["t"] as? Double, let wall = o["wall"] as? String, let date = ISO8601DateFormatter().date(from: wall) else { return nil }
    return date.timeIntervalSince1970 - t / 1000
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
    /// Keyboard sessions left out: an iPad's, whose layout depends on an orientation the log does not record.
    var sessionsSkipped = 0
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
    // words the user kept in an earlier session of the log stay kept, as Settings.learnedWords keeps them; words
    // kept before the log began are not in it
    var learned = Set<String>()
    // the line being replayed, and whether delete was pressed since the last word ended
    var lineT: Double = 0
    var deletedSince = false
    var boot: Double?
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
      out.words.append(Word(typed: typed, previous: previous, logged: early?.from == typed ? early?.to : nil, now: applied, bar: bar,
                            t: lineT, deleted: deletedSince, boot: boot))
      deletedSince = false
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
      lineT = o["t"] as? Double ?? 0
      if name == "appear" {
        boot = bootAnchor(o)
        guard (o["form"] as? String ?? "phone") == "phone" else {
          engine = nil  // the touches cannot be placed on the right keys
          out.sessionsSkipped += 1
          continue
        }
        let languages = (o["languages"] as? [String] ?? ["en"]).compactMap { lexicons[$0] }
        let layout = KeyboardLayout(width: CGFloat(o["width"] as? Double ?? 402), language: KeyboardLanguage(rawValue: o["layout"] as? String ?? "en") ?? .english)
        proxy = FakeProxy()
        let e = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: languages, layout: layout))
        e.learned = learned
        e.onLearn = { learned.insert($0) }
        engine = e
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
        case "delete": e.delete(); open = nil; deletedSince = true
        case "deleteWord": e.deleteWord(); open = nil; deletedSince = true
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

  /// What this engine made of a word typed in a typing exercise (the app's `exercise` lines), against the word
  /// the sentence asked for. Capitals and curly apostrophes are not told apart.
  enum Score: String, CaseIterable {
    case tappedRight = "tapped right", fixed = "fixed by autocorrect", wrongWord = "made a different wrong word"
    case leftAsTyped = "left as typed", notScored = "not scored"
  }

  struct Scored {
    var score: Score, target: String, word: Word?
    /// The sentence's word was in one of the bar's three slots when the word ended.
    var inBar: Bool { word.map { w in w.bar.contains { fold($0) == fold(target) } } ?? false }
  }

  static func fold(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "’", with: "'") }

  /// Each exercise sentence's words against the words this replay finished while the sentence was on screen, in
  /// the same boot of the phone. A sentence is not scored when the words finished or the words in the field at
  /// Next differ in number from the sentence's (a word left out, run together, not replayed, or deleted after it
  /// was finished), and nor is a word typed after a delete: which of the sentence's words it was is a guess.
  static func scoreExercises(_ lines: [String], _ out: Outcome) -> [Scored] {
    var scored: [Scored] = []
    for line in lines {
      guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], o["e"] as? String == "exercise",
            let t = o["t"] as? Double, let end = o["end"] as? Double, let target = o["target"] as? String else { continue }
      let want = TypingExerciseLog.words(target), anchor = bootAnchor(o)
      let typed = out.words.filter { w in
        t <= w.t && w.t <= end && (anchor == nil || w.boot == nil || abs(anchor! - w.boot!) <= bootSlack)
      }
      let final = TypingExerciseLog.words(o["typed"] as? String ?? "")
      guard typed.count == want.count, final.count == want.count else {
        scored += want.map { Scored(score: .notScored, target: $0, word: nil) }
        continue
      }
      for (w, target) in zip(typed, want) {
        let final = w.now ?? w.typed
        let score: Score =
          w.deleted ? .notScored
          : fold(final) == fold(target) ? (fold(w.typed) == fold(target) ? .tappedRight : .fixed)
          : w.now != nil ? .wrongWord : .leftAsTyped
        scored.append(Scored(score: score, target: target, word: w))
      }
    }
    return scored
  }

  @Test static func exerciseWordsAreScoredOnlyWhereTheyLineUp() {
    func word(_ typed: String, now: String? = nil, t: Double, deleted: Bool = false, bar: [String] = []) -> Word {
      Word(typed: typed, previous: nil, logged: nil, now: now, bar: bar, t: t, deleted: deleted)
    }
    var out = Outcome()
    // "The fox ran." typed as "teh" (corrected), "fox", then a delete before "ran"; "Sit by." with one word run on
    out.words = [word("teh", now: "the", t: 100, bar: ["teh", "the"]), word("fox", t: 200), word("ran", t: 300, deleted: true),
                 word("sitby", t: 1100), word("dog", now: "dig", t: 2100), word("cst", t: 2200),
                 // "go nw " finished, "nw" deleted and "now" typed: three words finished for two in the field
                 word("go", t: 3100), word("nw", t: 3200), word("now", t: 3300, deleted: true)]
    let lines = [#"{"t":50,"e":"exercise","end":400,"target":"The fox ran.","typed":"The fox ran."}"#,
                 #"{"t":1000,"e":"exercise","end":1200,"target":"Sit by.","typed":"Sitby"}"#,
                 #"{"t":2000,"e":"exercise","end":2300,"target":"dog cat","typed":"dig cst"}"#,
                 #"{"t":3000,"e":"exercise","end":3400,"target":"go now","typed":"go now"}"#]

    let scored = scoreExercises(lines, out)

    #expect(scored.map { "\($0.target) \($0.score.rawValue) \($0.inBar)" } == [
      "The fixed by autocorrect true", "fox tapped right false", "ran not scored false",
      "Sit not scored false", "by not scored false",
      "dog made a different wrong word false", "cat left as typed false",
      "go not scored false", "now not scored false",
    ])
  }

  @Test static func aSentenceWhoseLastWordWasDeletedBeforeNextIsNotScored() {
    var out = Outcome()
    // "Sit by " typed, then "by " deleted and Next tapped: both words were finished, one is gone from the field
    out.words = [Word(typed: "Sit", previous: nil, logged: nil, now: nil, bar: [], t: 100),
                 Word(typed: "by", previous: nil, logged: nil, now: nil, bar: [], t: 200)]
    let lines = [#"{"t":50,"e":"exercise","end":400,"target":"Sit by.","typed":"Sit "}"#]

    #expect(scoreExercises(lines, out).map(\.score) == [.notScored, .notScored])
  }

  @Test static func wordsFromAnotherBootAreLeftOutOfTheSentence() {
    var out = Outcome()
    let here = 1_794_470_409.95, otherBoot = here + 2 * 86_400
    // the sentence appeared at uptime 50 ms, at 08:00:10 UTC on 12 Nov 2026; "dog" was typed at the same uptime two days on
    out.words = [Word(typed: "Sit", previous: nil, logged: nil, now: nil, bar: [], t: 100, boot: here),
                 Word(typed: "dog", previous: nil, logged: nil, now: nil, bar: [], t: 150, boot: otherBoot),
                 Word(typed: "by", previous: nil, logged: nil, now: nil, bar: [], t: 200, boot: here)]
    let lines = [#"{"t":50,"e":"exercise","end":400,"wall":"2026-11-12T08:00:10Z","target":"Sit by.","typed":"Sit by."}"#]

    #expect(scoreExercises(lines, out).map(\.score) == [.tappedRight, .tappedRight])
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
    print("replay-summary word boundaries \(out.boundaries), left the bar empty \(out.emptyBars); words not replayed \(out.notReplayed); iPad sessions not replayed \(out.sessionsSkipped)")
    let scored = scoreExercises(lines, out)
    if !scored.isEmpty {
      for s in scored {
        print("replay-exercise \(s.score.rawValue): target=\(s.target) typed=\(s.word?.typed ?? "-") now=\(s.word?.now ?? "-") bar=\(s.word?.bar ?? [])")
      }
      let counts = Score.allCases.map { c in "\(c.rawValue) \(scored.filter { $0.score == c }.count)" }.joined(separator: ", ")
      let inBar = scored.filter { $0.score != .notScored && $0.inBar }.count
      print("replay-exercise-summary words \(scored.count): \(counts); target in the bar \(inBar)")
    }
    #expect(!out.words.isEmpty)
  }
}
