import V2TSpeech

/// The speech model as DictationService uses it: `SpeechEngine` (V2TSpeech) in the app, a stub in unit tests (as
/// `AudioSource` stands in for the microphone).
protocol SpeechModel: Sendable {
  func prepare(language: String, allowDownload: Bool, progress: @escaping @Sendable (SpeechEngine.State) -> Void) async throws
  func unload() async
  func transcribe(_ samples: [Float], language: String) async throws -> String
}

extension SpeechEngine: SpeechModel {}
