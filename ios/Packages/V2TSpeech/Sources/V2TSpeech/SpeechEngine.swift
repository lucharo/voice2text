import FluidAudio
import Foundation

/// On-device speech to text through FluidAudio on the Neural Engine. The model is fetched once from Hugging
/// Face at a pinned revision, then loaded from the app's own storage; audio never leaves the phone.
public actor SpeechEngine {
  public enum State: Equatable, Sendable {
    case notDownloaded, downloading(Double), loading, ready, failed(String)
    public var isPreparing: Bool {
      switch self {
      case .downloading, .loading: true
      default: false
      }
    }
  }

  /// Model repositories pinned to the revisions the phone benchmarks used (checked 2026-11-02).
  public static let pins = [
    "FluidInference/nemotron-labs-unified-asr-0.6b-coreml": "bd13ddde81d3134719c520845346b3252daf3175",
    "FluidInference/parakeet-tdt-0.6b-v3-coreml": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
  ]

  public let speech: Model
  /// The folder FluidAudio downloads to and loads from, holding one folder per model; nil for FluidAudio's own
  /// default under this app's Application Support.
  public let modelsDirectory: URL?
  private var nemotron: UnifiedAsrManager?
  private var nemotronLanguage: NemotronUnifiedLanguage?
  private var parakeet: AsrManager?
  public private(set) var state: State = .notDownloaded
  /// Bumped by unload(): work that awaited across it finds the number changed and drops its result.
  private var generation = 0

  /// `modelsDirectory`: where the model's files live (see `modelsDirectory(appGroup:)` to share them between the
  /// apps of one App Group); nil keeps FluidAudio's default. `ModelStore.forDevice` takes the same folder.
  public init(speech: Model, modelsDirectory: URL? = nil) {
    self.speech = speech
    self.modelsDirectory = modelsDirectory
    ModelRegistry.revisionOverrides = Self.pins
  }

  /// Loads the model, downloading what is missing only when `allowDownload` (the user tapped Download or Try
  /// again). Otherwise FluidAudio runs offline: nothing is fetched, and a damaged copy is reported, never
  /// deleted and downloaded again. `progress` reports `.downloading` only while files actually download.
  public func prepare(language: String, allowDownload: Bool, progress: @escaping @Sendable (State) -> Void) async throws {
    // FluidAudio-wide, so preparations must never overlap: the v2t app's DictationService runs one at a time
    ModelHub.offlineMode = !allowDownload
    state = .loading
    let handler: ProgressHandler = { p in progress(Self.state(for: p)) }
    do {
      switch speech {
      case .nemotron:
        let lang = Self.nemotronLanguage(language)
        let m = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(lang)), encoderPrecision: .int8)
        // Nemotron takes the folder that holds the model's folder, Parakeet the model's folder itself
        try await m.loadModels(to: modelsDirectory, configuration: nil, progressHandler: handler)
        nemotron = m
        nemotronLanguage = lang
      case .parakeet:
        let models = try await AsrModels.downloadAndLoad(
          to: modelsDirectory.map { Self.modelFolder(for: .parakeet, in: $0) }, version: .v3, encoderPrecision: .int8V2,
          progressHandler: handler)
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
  public func unload() {
    generation += 1  // a language reload already under way must not attach its model afterwards
    nemotron = nil
    nemotronLanguage = nil
    parakeet = nil
    state = .notDownloaded
  }

  /// Whether `folder` holds every file the model loads (FluidAudio's own lists at the pinned 55f65d9).
  public static func isComplete(_ speech: Model) -> @Sendable (URL) -> Bool {
    switch speech {
    case .nemotron:
      let family = UnifiedConfig(family: .nemotronMultilingual(.en)).family
      let names = [family.offlineEncoderFile(precision: .int8), family.decoderFile, family.jointDecisionFile, family.vocab]
      return { ModelStore.hasAll(names, in: $0) }
    case .parakeet:
      // modelsExist only checks that the paths exist; also reject half-downloaded bundles
      return { AsrModels.modelsExist(at: $0, version: .v3, encoderPrecision: .int8V2) && ModelStore.allBundlesLoadReady(in: $0) }
    }
  }

  /// Where this model's downloaded files live: FluidAudio's folder for it inside `modelsDirectory`, or inside
  /// FluidAudio's default (`defaultModelsDirectory`) when that is nil.
  public static func modelFolder(for speech: Model, in modelsDirectory: URL? = nil) -> URL {
    // FluidAudio's path for the model's repository, two folders deep for Nemotron (`MLModelConfigurationUtils.
    // defaultModelsDirectory(for:)`, `AsrModels.defaultCacheDirectory(for: .v3)` at the pinned 55f65d9)
    let repo: Repo = switch speech {
    case .nemotron: UnifiedConfig(family: .nemotronMultilingual(.en)).family.repo
    case .parakeet: .parakeetV3
    }
    return (modelsDirectory ?? defaultModelsDirectory).appending(path: repo.folderName, directoryHint: .isDirectory)
  }

  /// FluidAudio's own models folder, under this app's Application Support: where the model lives by default.
  public static var defaultModelsDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory() }

  /// `FluidAudio/Models` in the container of `appGroup`, an App Group this app belongs to: every app of the group
  /// that passes it downloads the model once and loads the same files. Created and kept out of device backups:
  /// the files download again on request, and Apple's storage guidelines ask for that. Nil when the app is not in
  /// the group.
  public static func modelsDirectory(appGroup: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map(modelsDirectory(inContainer:))
  }

  static func modelsDirectory(inContainer container: URL) -> URL {
    var models = container.appending(path: "FluidAudio/Models", directoryHint: .isDirectory)
    // on the folder, so it covers every file downloaded into it later; a failure leaves the files in backups
    try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? models.setResourceValues(values)
    return models
  }

  /// Moves this app's download of `speech` from `oldDirectory` (FluidAudio's default) into `modelsDirectory`, and
  /// returns the folder to give `init` and `ModelStore.forDevice`: `modelsDirectory`, or `oldDirectory` while the
  /// move fails and the download there is complete, so a failed move never costs a working model. Call it at every
  /// launch, before the model loads: once the old folder is gone it does nothing, and after an interruption it
  /// carries on (`ModelStore.moveDownload`).
  public static func moveDownload(of speech: Model, into modelsDirectory: URL, from oldDirectory: URL = defaultModelsDirectory) -> URL {
    let old = modelFolder(for: speech, in: oldDirectory)
    do {
      try ModelStore.moveDownload(from: old, to: modelFolder(for: speech, in: modelsDirectory), isComplete: isComplete(speech))
      return modelsDirectory
    } catch {
      return isComplete(speech)(old) ? oldDirectory : modelsDirectory
    }
  }

  /// 16 kHz mono samples to text.
  public func transcribe(_ samples: [Float], language: String) async throws -> String {
    switch speech {
    case .nemotron:
      guard state == .ready else { throw EngineError.notReady }  // unloaded (deleted): never reload from files
      let lang = Self.nemotronLanguage(language)
      if lang != nemotronLanguage {
        let started = generation
        // the language prompt is fixed per manager: reload with the new one from the local files, offline
        ModelHub.offlineMode = true
        let m = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(lang)), encoderPrecision: .int8)
        try await m.loadModels(to: modelsDirectory, configuration: nil, progressHandler: nil)
        guard started == generation else { throw EngineError.notReady }  // unloaded meanwhile
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

  public enum EngineError: LocalizedError {
    case notReady
    public var errorDescription: String? { "The speech model is not loaded yet." }
  }

  /// "auto" lets Nemotron pick, which measured slightly worse on Spanish (FLEURS 3.60% vs 3.38% told, #85).
  static func nemotronLanguage(_ code: String) -> NemotronUnifiedLanguage {
    NemotronUnifiedLanguage(rawValue: code) ?? .en
  }
}
