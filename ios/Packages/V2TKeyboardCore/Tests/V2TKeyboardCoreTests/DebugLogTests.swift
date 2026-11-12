import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
  var now: TimeInterval = 1000
}

struct DebugLogTests {
  func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "kblog-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  func lines(_ dir: URL) -> [[String: Any]] {
    String(decoding: (try? KeyboardDebugLog.merged(in: dir)) ?? Data(), as: UTF8.self).split(separator: "\n").map {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? ["unparsable": String($0)]
    }
  }

  @Test func offByDefaultWritesNothing() {
    let dir = tempDir()
    let log = KeyboardDebugLog(directory: dir)
    #expect(!log.isOn)
    log.log("key", [LogField("text", .s("a"))])
    log.flush(wait: true)
    #expect(KeyboardDebugLog.files(in: dir).isEmpty)
  }

  @Test func writesOneJSONLinePerEventInOrder() {
    let dir = tempDir(), clock = TestClock()
    let log = KeyboardDebugLog(directory: dir, clock: { clock.now })
    log.start(until: Date().addingTimeInterval(3600))
    #expect(log.isOn)
    log.log("key", [LogField("text", .s("\"a\\\n")), LogField("p", .pt(CGPoint(x: 12.345, y: 7)))])
    log.log("bar", [LogField("words", .list([.s("the"), .s("they")])), LogField("bold", .null), LogField("ok", .b(true))], at: 1000.5)
    log.flush(wait: true)
    let got = lines(dir)
    #expect(got.count == 2)
    #expect(got[0]["e"] as? String == "key")
    #expect(got[0]["text"] as? String == "\"a\\\n")
    #expect(got[0]["p"] as? [Double] == [12.3, 7])
    #expect(got[0]["t"] as? Double == 1_000_000)
    #expect(got[1]["t"] as? Double == 1_000_500)
    #expect(got[1]["words"] as? [String] == ["the", "they"])
    #expect(got[1]["bold"] is NSNull)
  }

  @Test func turnsItselfOffAtTheDeadline() {
    let dir = tempDir(), clock = TestClock()
    let log = KeyboardDebugLog(directory: dir, clock: { clock.now })
    let now = Date()
    log.start(until: now.addingTimeInterval(24 * 3600), now: now)
    log.log("key", [LogField("text", .s("a"))])
    clock.now += 24 * 3600 + 1
    #expect(!log.isOn)
    log.log("key", [LogField("text", .s("b"))])
    log.log("key", [LogField("text", .s("c"))])
    log.flush(wait: true)
    #expect(lines(dir).map { $0["e"] as? String } == ["key", "auto-off"])
  }

  @Test func aDeadlineAlreadyPastLeavesItOff() {
    let log = KeyboardDebugLog(directory: tempDir())
    log.start(until: Date().addingTimeInterval(-1))
    #expect(!log.isOn)
  }

  @Test func suspendedRecordsNothing() {
    let dir = tempDir()
    let log = KeyboardDebugLog(directory: dir)
    log.start(until: Date().addingTimeInterval(60))
    log.suspend(true)
    log.log("key", [LogField("text", .s("secret"))])
    log.suspend(false)
    log.log("key", [LogField("text", .s("a"))])
    log.flush(wait: true)
    #expect(lines(dir).map { $0["text"] as? String } == ["a"])
  }

  @Test func rotatesPastTheSizeCapAndKeepsTwoFiles() {
    let dir = tempDir()
    let log = KeyboardDebugLog(directory: dir, maxFileBytes: 2000, flushCount: 10)
    log.start(until: Date().addingTimeInterval(60))
    for i in 0..<500 { log.log("key", [LogField("i", .i(i))]) }
    log.flush(wait: true)
    let files = KeyboardDebugLog.files(in: dir)
    #expect(files.map(\.lastPathComponent) == ["keyboard.1.jsonl", "keyboard.jsonl"] || files.map(\.lastPathComponent) == ["keyboard.1.jsonl"])
    #expect(KeyboardDebugLog.size(in: dir) <= 2 * 2000 + 1000)
    // what is kept is the newest events, in order
    let kept = lines(dir).compactMap { $0["i"] as? Int }
    #expect(kept.last == 499)
    #expect(kept == Array(kept.first!...499))
    KeyboardDebugLog.clear(in: dir)
    #expect(KeyboardDebugLog.files(in: dir).isEmpty)
  }

  @Test func clearDropsEventsStillWaitingToBeWritten() {
    let dir = tempDir(), clock = TestClock()
    let log = KeyboardDebugLog(directory: dir, clock: { clock.now })
    log.start(until: Date().addingTimeInterval(3600))
    log.log("key", [LogField("text", .s("before"))])
    Thread.sleep(forTimeInterval: 0.02)
    KeyboardDebugLog.clear(in: dir)  // the app clears while the keyboard still holds it
    Thread.sleep(forTimeInterval: 0.02)
    log.log("key", [LogField("text", .s("after"))])
    log.flush(wait: true)
    #expect(lines(dir).map { $0["text"] as? String } == ["after"])
  }

  @Test func flushesOnItsOwnAfterTheDelay() async throws {
    let dir = tempDir()
    let log = KeyboardDebugLog(directory: dir, flushDelay: 0.05)
    log.start(until: Date().addingTimeInterval(60))
    log.log("key", [LogField("text", .s("a"))])
    // nothing else flushes: the line can only come from the timer. Polled, since a loaded Mac can run the
    // utility-queue timer well after its 0.05 s
    let deadline = ContinuousClock.now + .seconds(5)
    while lines(dir).isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(lines(dir).count == 1)
  }

  @Test func samplesKeepTheEnds() {
    let pts = (0..<100).map { CGPoint(x: Double($0), y: 0) }
    let s = KeyboardDebugLog.sample(pts, limit: 5)
    #expect(s.map(\.x) == [0, 25, 50, 74, 99] || s.map(\.x) == [0, 25, 50, 74, 99].map { CGFloat($0) })
    #expect(s.first?.x == 0 && s.last?.x == 99 && s.count == 5)
    #expect(KeyboardDebugLog.sample(Array(pts.prefix(3)), limit: 5).count == 3)
  }

  @Test func engineReportsCorrectionsRevertsPicksAndSwipes() throws {
    let p = FakeProxy()
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: KeyboardLayout(width: 402, language: .english)))
    var events: [TypingEngine.Event] = []
    e.onEvent = { events.append($0) }
    e.resync()
    for ch in "teh" { e.character(String(ch)) }
    e.space()
    #expect(p.text == "The ")
    e.delete()
    e.pick("Teh")
    #expect(p.text == "Teh ")
    for ch in "keyb" { e.character(String(ch)) }
    e.pick("keyboard")
    e.swipe(["hello", "jello"])
    #expect(events == [
      .autocorrected(original: "Teh", replacement: "The"),
      .revertOffered(original: "Teh", replacement: "The"),
      .reverted(original: "Teh", replacement: "The", how: "bar"),
      .picked(word: "keyboard", replaced: "keyb"),
      .swiped(word: "hello", alternatives: ["jello"]),
    ])
  }

  @Test func engineMarksAWordReadBackFromTheDocument() throws {
    let p = FakeProxy()
    p.text = "dictated marimo"
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: KeyboardLayout(width: 402, language: .english)))
    e.resync()
    #expect(e.composingResynced)  // "marimo" came from the document
    e.character("x")
    #expect(e.composingResynced)  // "marimox" still holds it
    e.space()
    #expect(!e.composingResynced)
    e.character("a")
    #expect(!e.composingResynced)  // typed here
  }

  @Test func aCorrectionOfAWordReadBackStaysReadBack() throws {
    let p = FakeProxy()
    p.text = "te"
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [try Fixtures.english.get()], layout: KeyboardLayout(width: 402, language: .english)))
    e.resync()
    e.character("h")
    e.space()  // "teh" -> "the"
    #expect(e.holdsReadBackText)
    e.delete()  // the original is offered back
    #expect(e.holdsReadBackText)
    e.character("m")  // typing on reopens the corrected word: still read back
    #expect(e.holdsReadBackText)
    e.space()
    e.character("a")
    #expect(!e.holdsReadBackText)
  }

  @Test func overlappingFlushesKeepTheOrder() {
    let dir = tempDir()
    let log = KeyboardDebugLog(directory: dir, flushCount: 3, flushDelay: 0.001)
    log.start(until: Date().addingTimeInterval(60))
    for i in 0..<300 { log.log("key", [LogField("i", .i(i))]) }
    log.flush(wait: true)
    #expect(lines(dir).compactMap { $0["i"] as? Int } == Array(0..<300))
  }


  /// The logging call itself, on the calling thread (the keyboard's main thread): buffered, no file access.
  @Test func oneLogCallCostsMicroseconds() {
    let log = KeyboardDebugLog(directory: tempDir())
    log.start(until: Date().addingTimeInterval(600))
    let n = 20_000, start = ContinuousClock.now
    for i in 0..<n { log.log("key", [LogField("text", .s("a")), LogField("p", .pt(CGPoint(x: Double(i), y: 3)))]) }
    let d = (ContinuousClock.now - start).components
    let perCall = (Double(d.seconds) * 1e6 + Double(d.attoseconds) / 1e12) / Double(n)
    log.flush(wait: true)
    print(String(format: "debuglog: one log() call %.2f µs on the calling thread", perCall))
    #expect(perCall < 50)
  }

  /// What logging adds to a key on the Mac. Types the same sentences with the log off and on, interleaved
  /// sentence by sentence (which goes first alternates), with every event the keyboard records for a key (key,
  /// proxy edits, engine decisions, a changed bar), and compares each key with the same key typed with the log
  /// off a moment earlier or later: the median of those differences is what the log adds, and a busy Mac slows
  /// both arms of a pair alike. The p99 against the README's 8 ms budget is a property of the whole machine
  /// (full-suite runs beside Simulator jobs read 8.4 to 19.4 ms, #195), so it is checked only when
  /// V2T_KEY_BUDGET_MS is set, as testflight.yml's latency job does on its own runner. Release build only, as
  /// RealTypoEval: `swift test -c release -Xswiftc -enable-testing --filter perKeyCost 2>&1 | grep '^debuglog'`.
  @Test(.enabled(if: RealTypoEval.optimised, "timings mean nothing in a debug build"))
  func perKeyCostWithTheLogOn() throws {
    let lexicons = [try Fixtures.english.get()]
    let layout = KeyboardLayout(width: 402, language: .english)
    let sentences = Array(repeating: ["teh quick brown fox jumsp over the lazy dog", "i wnat to go home now becuase its late",
                                      "thsi keyboard shoudl learn from what i type"], count: 20).flatMap { $0 }
    let log = KeyboardDebugLog(directory: tempDir())
    log.start(until: Date().addingTimeInterval(600))
    func type(_ s: String, _ log: KeyboardDebugLog?, into times: inout [Double]) {
      let proxy = LoggingProxy(log: log)
      let e = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: lexicons, layout: layout))
      if let log { e.onEvent = { log.log("engine", [LogField("what", .s("\($0)"))]) } }
      e.resync()
      var lastBar: [String] = []
      for ch in s {
        let start = ContinuousClock.now
        let key = layout.keys.first { $0.label == String(ch) }
        if let log, log.isOn { log.log("key", [LogField("text", .s(String(ch))), LogField("p", .pt(key?.center ?? .zero))]) }
        if ch == " " { e.space() } else { e.character(String(ch), at: key?.center) }
        let bar = e.suggestions().map(\.word), bold = e.pendingAutocorrection
        if let log, log.isOn, bar != lastBar {
          log.log("bar", [LogField("words", .list(bar.map { .s($0) })), LogField("bold", bold.map { .s($0) } ?? .null)])
        }
        lastBar = bar
        let d = (ContinuousClock.now - start).components
        times.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
      }
    }
    var warm: [Double] = [], off: [Double] = [], on: [Double] = []
    for s in sentences.prefix(3) { type(s, nil, into: &warm) }
    for (i, s) in sentences.enumerated() {
      if i.isMultiple(of: 2) {
        type(s, nil, into: &off)
        type(s, log, into: &on)
      } else {
        type(s, log, into: &on)
        type(s, nil, into: &off)
      }
    }
    log.flush(wait: true)
    print("debuglog per key, log off: \(RealTypoEval.stats(off))")
    print("debuglog per key, log on:  \(RealTypoEval.stats(on))")
    try #require(on.count == off.count)
    let added = zip(on, off).map { $0 - $1 }.sorted()
    let medianAdded = added[added.count / 2]
    print(String(format: "debuglog: added per key, median %.4f ms", medianAdded))
    #expect(medianAdded < Self.addedBudgetMs, "the log adds \(medianAdded) ms to the median key")
    if let budget = ProcessInfo.processInfo.environment["V2T_KEY_BUDGET_MS"].flatMap(Double.init) {
      let p99 = on.sorted()[on.count * 99 / 100]
      #expect(p99 < budget, "p99 \(p99) ms over the \(budget) ms budget")
    }
  }

  /// What the log may add to the median key. Measured on a 10-core Mac at load 73 to 93 (12 Nov 2026): 0.003 to
  /// 0.007 ms; with a 50 µs sleep in each log() call, 0.41 ms; with each call waiting for its write to disk, 10.8 ms.
  static let addedBudgetMs = 0.1
}

/// The keyboard's ProxyAdapter in miniature: records inserts and deletes when the log is on.
final class LoggingProxy: TextProxy {
  let inner = FakeProxy()
  let log: KeyboardDebugLog?
  init(log: KeyboardDebugLog?) { self.log = log }
  var documentContextBeforeInput: String? { inner.documentContextBeforeInput }
  func insertText(_ text: String) {
    if let log, log.isOn { log.log("ins", [LogField("text", .s(text))]) }
    inner.insertText(text)
  }
  func deleteBackward() {
    if let log, log.isOn { log.log("del") }
    inner.deleteBackward()
  }
}
