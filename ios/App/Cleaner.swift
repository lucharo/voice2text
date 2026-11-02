import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import V2TCleanup

/// Tidies a transcript on the device with Apple Intelligence, set up as measured on an iPhone 16 Pro (#67):
/// the Mac app's casual prompt with the dictionary as instructions, each chunk framed as "Dictation: …
/// Cleaned:" under the permissive content guardrails (0 refusals in 600), greedy, at most 3x the chunk's
/// words, 30 s per chunk. Every chunk then passes the Mac's guards: a length guard, and keep_spoken_words,
/// which puts back any word the model dropped or changed that it had no licence to (fillers, repeats,
/// numbers in digits and dictionary spellings excepted). Any failure keeps the words as heard.
struct Cleaner: Sendable {
  let kind: Recommendation.Cleanup

  func clean(_ text: String, terms: [String]) async -> String {
    guard kind == .appleIntelligence else { return text }
    #if canImport(FoundationModels)
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    guard case .available = model.availability else { return text }
    var parts: [String] = []
    for chunk in chunkText(text) {
      let instructions = CleanupPrompt.messages(for: chunk, mode: .casual, vocabulary: terms)[0].content
      let words = chunk.split(separator: " ").count
      let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: max(64, words * 3))
      let cleaned: String
      do {
        cleaned = try await withThrowingTaskGroup(of: String.self) { g in
          g.addTask {
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: "Dictation: \(chunk)\nCleaned:", options: options).content
          }
          g.addTask { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
          let first = try await g.next()!
          g.cancelAll()
          return first
        }
      } catch {
        parts.append(chunk)
        continue
      }
      let c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
      if c.isEmpty || !withinLengthGuard(raw: chunk, clean: c, mode: .casual) {
        parts.append(chunk)
      } else {
        parts.append(keepSpokenWords(raw: chunk, clean: c, vocabulary: terms).text)
      }
    }
    return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    #else
    return text
    #endif
  }
}
