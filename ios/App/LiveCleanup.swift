import Foundation
import V2TCleanup

/// Cleans one dictation while it is recorded, so after Stop only the text since the last settled sentence is
/// left for Apple Intelligence. `CleanupStream` picks each segment from the pieces transcribed so far
/// (`LiveTranscription.onPieces`); segments are cleaned one at a time, in order, each through `Cleaner` with its
/// chunking and guards. FoundationModels runs while the app is in the background, as it is whenever the
/// keyboard drives it, but there Apple may rate-limit it (`LanguageModelError.rateLimited`): a segment the model
/// did not answer for is cleaned again after Stop rather than kept as heard.
@MainActor final class LiveCleanup {
  typealias Clean = @Sendable (String, [String]) async -> (text: String, answered: Bool)

  private var stream: CleanupStream
  private let clean: Clean
  /// The dictionary's terms when recording began; a change by Stop means clean everything with the new ones.
  let terms: [String]
  /// Each segment as heard and, once cleaned, the result (nil until then, or when the model did not answer).
  private var segments: [(raw: String, cleaned: String?)] = []
  /// Every segment's cleaning, each waiting for the one before it.
  private var tasks: [Task<Void, Never>] = []
  private var closed = false

  init(terms: [String], minimumWords: Int = 30, clean: @escaping Clean) {
    self.terms = terms
    self.clean = clean
    stream = CleanupStream(minimumWords: minimumWords)
  }

  /// The pieces transcribed so far: cleans the next settled segment, if there is one, after any before it.
  func offer(pieces: [String]) {
    guard !closed, let segment = stream.next(pieces: pieces) else { return }
    let index = segments.count
    segments.append((segment, nil))
    let previous = tasks.last, clean = clean, terms = terms
    tasks.append(Task {
      await previous?.value
      // a segment still waiting its turn at Stop is not sent: it is cleaned with the rest, in one request
      guard !Task.isCancelled, !self.closed else { return }
      let result = await clean(segment, terms)
      if result.answered { self.segments[index].cleaned = result.text }
    })
  }

  /// The whole dictation cleaned: waits only for the segment the model is cleaning now (those still queued
  /// are not sent), keeps every one the model answered for, and cleans the rest now: what no segment covered,
  /// plus each run of segments that were not sent or not answered. `terms` are the dictionary's now; when they changed since recording began, or `text` does
  /// not begin with the segments (the recording was transcribed again as a whole), the segments are dropped
  /// unawaited and everything is cleaned now, as before cleanup while recording. Returns the text and how many
  /// segments were cleaned while recording and kept.
  func finish(_ text: String, terms now: [String]) async -> (text: String, cleanedWhileRecording: Int) {
    closed = true
    guard now == terms, let rest = stream.rest(of: text) else {
      for t in tasks { t.cancel() }
      return (await clean(text, now).text, 0)
    }
    await tasks.last?.value
    var parts: [String] = [], unanswered: [String] = [], kept = 0
    for segment in segments + [(raw: rest, cleaned: nil)] {
      if let cleaned = segment.cleaned {
        if !unanswered.isEmpty { parts.append(await clean(unanswered.joined(separator: " "), now).text) }
        unanswered = []
        parts.append(cleaned)
        kept += 1
      } else if !segment.raw.isEmpty {
        unanswered.append(segment.raw)
      }
    }
    if !unanswered.isEmpty { parts.append(await clean(unanswered.joined(separator: " "), now).text) }
    return (parts.filter { !$0.isEmpty }.joined(separator: " "), kept)
  }

  /// Stop was tapped: no segment still queued is sent from now on, while the last piece is transcribed.
  func stop() { closed = true }

  /// Waits for the segments sent so far; for tests, standing in for the time a recording takes.
  func idle() async { await tasks.last?.value }

  /// The dictation was dropped: no further segment is sent to the model.
  func abandon() {
    closed = true
    for t in tasks { t.cancel() }
  }
}
