import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import V2TCleanup
import os

private let log = Logger(subsystem: "es.luischav.v2t", category: "cleanup")

/// Tidies a transcript on the device with Apple Intelligence, set up as measured on an iPhone 16 Pro (#67):
/// the Mac app's casual prompt with the dictionary as instructions, each chunk labelled as dictation in a
/// quoted block (CleanupPrompt.appleFrame, #126) under the permissive content guardrails (0 refusals in
/// 600), greedy, at most 3x the chunk's words, 30 s per chunk. Every chunk then passes the Mac's guards: a length guard, and keep_spoken_words,
/// which puts back any word the model dropped or changed that it had no licence to (fillers, repeats,
/// numbers in digits and dictionary spellings excepted). Any failure keeps the words as heard.
struct Cleaner: Sendable {
  let kind: Recommendation.Cleanup

  /// `mode`: casual (the app's setting, with the spoken-words guard) or strict ("thorough": drops fillers and
  /// false starts, length guard only, as on the Mac), the latter for the cleanup comparison (#122).
  func clean(_ text: String, terms: [String], mode: CleanupMode = .casual) async -> String {
    await cleanReporting(text, terms: terms, mode: mode).text
  }

  /// `clean`, also saying whether the model answered for every chunk: false when one timed out, failed (in
  /// the background Apple rate-limits the model, `LanguageModelError.rateLimited`) or was cancelled and so
  /// kept its words as heard, or when cleanup could not run at all.
  func cleanReporting(_ text: String, terms: [String], mode: CleanupMode = .casual) async -> (text: String, answered: Bool) {
    guard kind == .appleIntelligence else { log.info("cleanup skipped: not recommended on this iPhone"); return (text, false) }
    #if canImport(FoundationModels)
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    guard case .available = model.availability else { log.info("cleanup skipped: Apple Intelligence unavailable"); return (text, false) }
    var parts: [String] = []
    var answered = true
    for chunk in chunkText(text) {
      if Task.isCancelled { parts.append(chunk); answered = false; continue }  // a cancelled run stops asking the model
      let instructions = CleanupPrompt.messages(for: chunk, mode: mode, vocabulary: terms)[0].content
      let words = chunk.split(separator: " ").count
      let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: max(64, words * 3))
      let cleaned: String
      do {
        cleaned = try await withThrowingTaskGroup(of: String.self) { g in
          g.addTask {
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: CleanupPrompt.appleFrame(chunk), options: options).content
          }
          g.addTask { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
          let first = try await g.next()!
          g.cancelAll()
          return first
        }
      } catch {
        parts.append(chunk)
        answered = false
        continue
      }
      let c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
      if c.isEmpty || !withinLengthGuard(raw: chunk, clean: c, mode: mode) {
        parts.append(chunk)
      } else {
        parts.append(mode == .casual ? keepSpokenWords(raw: chunk, clean: c, vocabulary: terms).text : c)
      }
    }
    let out = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    log.info("cleanup ran: \(parts.count, privacy: .public) chunks, \(terms.count, privacy: .public) terms, changed \(out != text, privacy: .public)")
    return (out, answered)
    #else
    return (text, false)
    #endif
  }
}
