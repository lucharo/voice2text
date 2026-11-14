import FluidAudio
import Foundation
import Testing
@testable import V2TSpeech

/// Where the model lives when the caller names a folder (an App Group's container), and what stays as it was
/// when it names none.
struct ModelsDirectoryTests {
  let root = FileManager.default.temporaryDirectory.appending(path: "v2t-models-dir-\(UUID().uuidString)")
  var shared: URL { root.appending(path: "Group/FluidAudio/Models") }
  var own: URL { root.appending(path: "AppSupport/FluidAudio/Models") }
  let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

  func write(_ bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: bytes).write(to: url)
  }

  /// Every file Nemotron loads, as FluidAudio checks them before loading, with the revision it was pinned at.
  func writeCompleteNemotron(in models: URL) throws {
    let folder = models.appending(path: "nemotron-labs-unified-asr/coreml")
    let family = UnifiedConfig(family: .nemotronMultilingual(.en)).family
    for bundle in [family.offlineEncoderFile(precision: .int8), family.decoderFile, family.jointDecisionFile] {
      try write(100, to: folder.appending(path: "\(bundle)/coremldata.bin"))
      try write(100, to: folder.appending(path: "\(bundle)/weights/weight.bin"))
    }
    try write(100, to: folder.appending(path: "vocab.json"))
    let pin = try #require(SpeechEngine.pins["FluidInference/nemotron-labs-unified-asr-0.6b-coreml"])
    try Data(pin.utf8).write(to: folder.appending(path: ".fluidaudio-revision"))
  }

  @Test func withNoFolderTheModelStaysWhereFluidAudioPutsItToday() {
    let models = home.appending(path: "FluidAudio/Models")

    #expect(SpeechEngine.modelFolder(for: .nemotron).path == models.appending(path: "nemotron-labs-unified-asr/coreml").path)
    #expect(SpeechEngine.modelFolder(for: .parakeet).path == models.appending(path: "parakeet-tdt-0.6b-v3").path)
    #expect(ModelStore.forDevice(.nemotron).folders.map(\.path) == [
      models.path, URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "es.luischav.v2t")/com.apple.e5rt.e5bundlecache").path,
    ])
  }

  @Test func aNamedFolderHoldsTheModelAndIsMeasuredWithTheAppsOwnFolder() {
    let store = ModelStore.forDevice(.parakeet, modelsDirectory: shared)

    #expect(SpeechEngine.modelFolder(for: .nemotron, in: shared).path == shared.appending(path: "nemotron-labs-unified-asr/coreml").path)
    #expect(store.modelFolder.path == shared.appending(path: "parakeet-tdt-0.6b-v3").path)
    #expect(store.folders.map(\.path) == [
      shared.path, home.appending(path: "FluidAudio/Models").path,
      URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "es.luischav.v2t")/com.apple.e5rt.e5bundlecache").path,
    ])
  }

  @Test func theSharedFolderIsInsideTheAppGroupsContainer() {
    #expect(SpeechEngine.modelsDirectory(inContainer: root).path == root.appending(path: "FluidAudio/Models").path)
  }

  /// The model downloads again on request, so it stays out of device backups (it is 0.6 GB).
  @Test func theSharedFolderIsKeptOutOfBackups() throws {
    let models = SpeechEngine.modelsDirectory(inContainer: root)

    let values = try models.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  /// Offline, with every file in the named folder, FluidAudio gets past its check for missing files there and
  /// tries to load them (these are not real models, so loading fails); looking anywhere else, it finds nothing.
  @Test func prepareLoadsNemotronFromTheNamedFolder() async throws {
    try writeCompleteNemotron(in: shared)
    let engine = SpeechEngine(speech: .nemotron, modelsDirectory: shared)

    let error = await #expect(throws: (any Error).self) { try await engine.prepare(language: "en", allowDownload: false) { _ in } }

    let missing = if case .modelMissing = error as? DownloadError { true } else { false }
    #expect(missing == false, "FluidAudio looked for the files elsewhere: \(String(describing: error))")
  }

  /// Deleting the model removes the folder and its exclusion; the next preparation, before any download into it,
  /// excludes it again.
  @Test func aNamedFolderIsKeptOutOfBackupsWhenPreparationRecreatesIt() async throws {
    let engine = SpeechEngine(speech: .nemotron, modelsDirectory: shared)

    _ = try? await engine.prepare(language: "en", allowDownload: false) { _ in }  // nothing there: fails offline

    let values = try shared.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test func aMovedDownloadIsUsedFromTheSharedFolder() throws {
    try writeCompleteNemotron(in: own)

    let models = SpeechEngine.moveDownload(of: .nemotron, into: shared, from: own)

    #expect(models == shared)
    #expect(ModelStore.forDevice(.nemotron, modelsDirectory: models).isOnDevice)
  }

  /// The move fails (the old folder cannot leave its parent): the complete download is used where it is.
  @Test func aFailedMoveKeepsUsingTheCompleteOldDownload() throws {
    try writeCompleteNemotron(in: own)
    let parent = own.appending(path: "nemotron-labs-unified-asr")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

    let models = SpeechEngine.moveDownload(of: .nemotron, into: shared, from: own)

    #expect(models == own)
    #expect(SpeechEngine.isComplete(.nemotron)(SpeechEngine.modelFolder(for: .nemotron, in: models)))
  }

  /// The move fails and the old download was partial: the shared folder is used, where the model is not
  /// downloaded, so the user's Download fetches it there.
  @Test func aFailedMoveOfAPartialDownloadUsesTheSharedFolder() throws {
    try write(5_000, to: own.appending(path: "nemotron-labs-unified-asr/coreml/vocab.json.partial"))
    let parent = own.appending(path: "nemotron-labs-unified-asr")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

    let models = SpeechEngine.moveDownload(of: .nemotron, into: shared, from: own)

    #expect(models == shared)
    #expect(ModelStore.forDevice(.nemotron, modelsDirectory: models).isOnDevice == false)
  }
}
