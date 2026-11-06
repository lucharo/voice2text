import FluidAudio
import Foundation

/// On-device speech to text through FluidAudio on the Neural Engine. The model is fetched once from Hugging
/// Face at a pinned revision, then loaded from the app's own storage; audio never leaves the phone.
actor SpeechEngine {
  enum State: Equatable {
    case notDownloaded, downloading(Double), loading, ready, failed(String)
    var isPreparing: Bool {
      switch self {
      case .downloading, .loading: true
      default: false
      }
    }
  }

  /// Model repositories pinned to the revisions the phone benchmarks used (checked 2026-11-02).
  static let pins = [
    "FluidInference/nemotron-labs-unified-asr-0.6b-coreml": "bd13ddde81d3134719c520845346b3252daf3175",
    "FluidInference/parakeet-tdt-0.6b-v3-coreml": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
  ]

  let speech: Recommendation.Speech
  private var nemotron: UnifiedAsrManager?
  private var nemotronLanguage: NemotronUnifiedLanguage?
  private var parakeet: AsrManager?
  private(set) var state: State = .notDownloaded

  init(speech: Recommendation.Speech) {
    self.speech = speech
    ModelRegistry.revisionOverrides = Self.pins
  }

  /// Loads the model, downloading what is missing only when `allowDownload` (the user tapped Download or Try
  /// again). Otherwise FluidAudio runs offline: nothing is fetched, and a damaged copy is reported, never
  /// deleted and downloaded again. `progress` reports `.downloading` only while files actually download.
  func prepare(language: String, allowDownload: Bool, progress: @escaping @Sendable (State) -> Void) async throws {
    ModelHub.offlineMode = !allowDownload  // preparations never overlap: DictationService runs one at a time
    state = .loading
    let handler: ProgressHandler = { p in progress(Self.state(for: p)) }
    do {
      switch speech {
      case .nemotron:
        let lang = Self.nemotronLanguage(language)
        let m = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(lang)), encoderPrecision: .int8)
        try await m.loadModels(to: nil, configuration: nil, progressHandler: handler)
        nemotron = m
        nemotronLanguage = lang
      case .parakeet:
        let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8V2, progressHandler: handler)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        parakeet = m
      }
      state = .ready
    } catch {
      state = .failed(error.localizedDescription)
      throw error
    }
  }

  /// Drops the loaded model, before its files are deleted.
  func unload() {
    nemotron = nil
    nemotronLanguage = nil
    parakeet = nil
    state = .notDownloaded
  }

  /// Whether `folder` holds every file the model loads (FluidAudio's own lists at the pinned 55f65d9).
  static func isComplete(_ speech: Recommendation.Speech) -> @Sendable (URL) -> Bool {
    switch speech {
    case .nemotron:
      let family = UnifiedConfig(family: .nemotronMultilingual(.en)).family
      let names = [family.offlineEncoderFile(precision: .int8), family.decoderFile, family.jointDecisionFile, family.vocab]
      return { ModelStore.hasAll(names, in: $0) }
    case .parakeet:
      return { AsrModels.modelsExist(at: $0, version: .v3, encoderPrecision: .int8V2) }
    }
  }

  /// Where FluidAudio keeps this model's downloaded files (its default under Application Support).
  static func modelFolder(for speech: Recommendation.Speech) -> URL {
    switch speech {
    case .nemotron: MLModelConfigurationUtils.defaultModelsDirectory(for: UnifiedConfig(family: .nemotronMultilingual(.en)).family.repo)
    case .parakeet: AsrModels.defaultCacheDirectory(for: .v3)
    }
  }

  /// 16 kHz mono samples to text.
  func transcribe(_ samples: [Float], language: String) async throws -> String {
    switch speech {
    case .nemotron:
      let lang = Self.nemotronLanguage(language)
      if lang != nemotronLanguage {
        // the language prompt is fixed per manager: reload with the new one from the local files, offline
        ModelHub.offlineMode = true
        let m = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(lang)), encoderPrecision: .int8)
        try await m.loadModels(to: nil, configuration: nil, progressHandler: nil)
        nemotron = m
        nemotronLanguage = lang
      }
      guard let m = nemotron else { throw EngineError.notReady }
      return try await m.transcribe(samples)
    case .parakeet:
      guard let m = parakeet else { throw EngineError.notReady }
      var st = TdtDecoderState.make()
      return try await m.transcribe(samples, decoderState: &st).text
    }
  }

  /// FluidAudio's repo loads give the download the first half of `fractionCompleted` and compiling the
  /// rest (ProgressReporter, `downloadPhaseWeight: 0.5` at the pinned 55f65d9), so the bar shows the
  /// download alone. A cached model reports a download of zero files: nothing to download.
  static func state(for p: DownloadProgress) -> State {
    switch p.phase {
    case .listing: .downloading(0)
    case .downloading(_, let total) where total == 0: .loading
    case .downloading: .downloading(min(1, p.fractionCompleted / 0.5))
    case .compiling: .loading
    }
  }

  enum EngineError: LocalizedError {
    case notReady
    var errorDescription: String? { "The speech model is not loaded yet." }
  }

  /// "auto" lets Nemotron pick, which measured slightly worse on Spanish (FLEURS 3.60% vs 3.38% told, #85).
  static func nemotronLanguage(_ code: String) -> NemotronUnifiedLanguage {
    NemotronUnifiedLanguage(rawValue: code) ?? .en
  }
}
