import SwiftUI
import UIKit
import V2TCleanup

/// Measuring time to text on the phone (#122): History's timings as CSV for `ios/tools/timings_plot.py`, and the
/// same recent dictations cleaned three ways (off, casual, thorough) and timed, to compare cleanup settings.
enum TimingsCSV {
  /// One row per dictation that has timings, oldest first; no text, so it is safe to paste anywhere.
  static func make(_ items: [Dictation]) -> String {
    var out = "date,language,audio_s,speech_s,cleanup_s,total_s,pieces_while_recording\n"
    let iso = ISO8601DateFormatter()
    for d in items.reversed() {
      guard let t = d.timings else { continue }
      let cleanup = t.cleanup.map { String(format: "%.3f", $0) } ?? ""
      out += "\(iso.string(from: d.date)),\(d.language),\(String(format: "%.2f", t.audio)),\(String(format: "%.3f", t.speech)),"
        + "\(cleanup),\(String(format: "%.3f", t.total)),\(t.piecesWhileRecording)\n"
    }
    return out
  }
}

/// Word-level edit distance between two texts, case and punctuation ignored: how many words cleanup changed.
func wordEdits(_ a: String, _ b: String) -> Int {
  func words(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
  }
  let x = words(a), y = words(b)
  var prev = Array(0...y.count)
  for (i, w) in x.enumerated() {
    var cur = [i + 1]
    for (j, v) in y.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (w == v ? 0 : 1))) }
    prev = cur
  }
  return prev[y.count]
}

/// One dictation cleaned in one mode.
struct CleanupRun: Equatable, Sendable {
  var mode: String
  var seconds: Double
  var words: Int
  var wordsChanged: Int
}

enum CleanupComparison {
  /// CSV of every run: dictation index (1 = newest), its length, the mode, seconds, words in and changed.
  static func csv(_ runs: [[CleanupRun]], audio: [Double?]) -> String {
    var out = "dictation,audio_s,mode,cleanup_s,words,words_changed\n"
    for (i, row) in runs.enumerated() {
      let a = audio[i].map { String(format: "%.1f", $0) } ?? ""
      for r in row { out += "\(i + 1),\(a),\(r.mode),\(String(format: "%.3f", r.seconds)),\(r.words),\(r.wordsChanged)\n" }
    }
    return out
  }

  /// "casual 1.18 s, 2 words changed · thorough 1.40 s, 5 words changed" from the medians of each mode.
  static func summary(_ runs: [[CleanupRun]]) -> String {
    let modes = runs.first?.map(\.mode) ?? []
    return modes.map { m in
      let rs = runs.compactMap { $0.first { $0.mode == m } }
      func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
      return String(format: "%@ %.2f s, %.0f words changed", m, median(rs.map(\.seconds)), median(rs.map { Double($0.wordsChanged) }))
    }.joined(separator: " · ")
  }
}

struct TimingsToolbar: ToolbarContent {
  @EnvironmentObject var history: History
  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button("Copy timings (CSV)", systemImage: "doc.on.doc") { UIPasteboard.general.string = TimingsCSV.make(history.items) }
        NavigationLink { CompareCleanupView() } label: { Label("Compare cleanup", systemImage: "gauge.with.dots.needle.33percent") }
      } label: { Image(systemName: "stopwatch") }
        .accessibilityIdentifier("v2t.history.timings")
    }
  }
}

/// Cleans the latest dictations' heard words casually and thoroughly with Apple Intelligence, one at a time, and
/// shows the time and words changed per mode. Off is the heard text itself (0 s, nothing changed).
struct CompareCleanupView: View {
  @EnvironmentObject var history: History
  @EnvironmentObject var dictation: DictationService
  @EnvironmentObject var dictionary: PersonalDictionary
  @State private var runs: [[CleanupRun]] = []
  @State private var running = false
  static let count = 10

  var body: some View {
    let items = Array(history.items.prefix(Self.count))
    List {
      Section {
        Text("Cleans your last \(min(Self.count, items.count)) dictations two ways with Apple Intelligence, one after the other, and times each. Nothing leaves this \(dictation.recommendation.deviceName); History is not changed.")
          .font(.footnote).foregroundStyle(.secondary)
        Button(running ? "Cleaning…" : "Run") { Task { await run(items) } }
          .disabled(running || items.isEmpty || dictation.recommendation.cleanup != .appleIntelligence)
          .accessibilityIdentifier("v2t.compare.run")
        if dictation.recommendation.cleanup != .appleIntelligence {
          Text("Apple Intelligence is off or not available here, so there is nothing to compare.").font(.footnote)
        }
      }
      if !runs.isEmpty {
        Section("Median per dictation") {
          Text(CleanupComparison.summary(runs)).monospacedDigit()
          Button("Copy results (CSV)", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = CleanupComparison.csv(runs, audio: items.prefix(runs.count).map { $0.timings?.audio })
          }
        }
        Section("Each dictation") {
          ForEach(Array(runs.enumerated()), id: \.offset) { i, row in
            Text(row.map { String(format: "%@ %.2f s, %d changed", $0.mode, $0.seconds, $0.wordsChanged) }.joined(separator: " · "))
              .font(.caption).monospacedDigit()
              .accessibilityLabel("Dictation \(i + 1)")
          }
        }
      }
    }
    .navigationTitle("Compare cleanup")
  }

  private func run(_ items: [Dictation]) async {
    running = true
    runs = []
    let cleaner = Cleaner(kind: dictation.recommendation.cleanup), terms = dictionary.terms
    for d in items {
      let heard = d.heard ?? d.text
      var row: [CleanupRun] = []
      for mode in [CleanupMode.casual, .strict] {
        let t0 = ContinuousClock.now
        let out = await cleaner.clean(heard, terms: terms, mode: mode)
        row.append(CleanupRun(mode: mode == .strict ? "thorough" : "casual", seconds: (ContinuousClock.now - t0).seconds,
                              words: heard.split(separator: " ").count, wordsChanged: wordEdits(heard, out)))
      }
      runs.append(row)
    }
    running = false
  }
}
