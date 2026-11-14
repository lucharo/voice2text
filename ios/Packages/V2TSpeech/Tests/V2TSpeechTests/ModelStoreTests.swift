import Foundation
import Testing
@testable import V2TSpeech

/// The speech model's files: on the device or not, their size, and deleting them with the compiled copy.
struct ModelStoreTests {
  let root = FileManager.default.temporaryDirectory.appending(path: "v2t-models-\(UUID().uuidString)")
  var downloads: URL { root.appending(path: "FluidAudio/Models") }
  var compiled: URL { root.appending(path: "Caches/com.apple.e5rt.e5bundlecache") }
  /// The model needs an encoder folder and a vocabulary, as Nemotron does.
  var store: ModelStore {
    ModelStore(modelFolder: downloads.appending(path: "nemotron"), folders: [downloads, compiled]) {
      ModelStore.hasAll(["Encoder.mlmodelc", "vocab.json"], in: $0)
    }
  }

  /// A compiled model as a finished download leaves it: weights and the root coremldata.bin.
  func writeBundle(_ name: String) throws {
    try write(10_000, to: store.modelFolder.appending(path: "\(name)/weights/weight.bin"))
    try write(100, to: store.modelFolder.appending(path: "\(name)/coremldata.bin"))
  }

  func write(_ bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: bytes).write(to: url)
  }

  @Test func noFolderMeansNotOnDeviceAndNoSpace() {
    #expect(store.isOnDevice == false)
    #expect(store.bytes == 0)
  }

  @Test func anEmptyModelFolderIsNotOnDevice() throws {
    try FileManager.default.createDirectory(at: store.modelFolder, withIntermediateDirectories: true)

    #expect(store.isOnDevice == false)
  }

  @Test func everyRequiredFileMeansOnDevice() throws {
    try writeBundle("Encoder.mlmodelc")
    try write(100, to: store.modelFolder.appending(path: "vocab.json"))

    #expect(store.isOnDevice)
  }

  /// Interrupted mid-weights: the bundle folder and the vocabulary exist, but no coremldata.bin yet.
  @Test func aBundleWithoutItsCoreMLDataIsNotOnDevice() throws {
    try write(10_000, to: store.modelFolder.appending(path: "Encoder.mlmodelc/weights/weight.bin"))
    try write(100, to: store.modelFolder.appending(path: "vocab.json"))

    #expect(store.isOnDevice == false)
  }

  @Test func aBundleWithAPartialFileIsNotOnDevice() throws {
    try writeBundle("Encoder.mlmodelc")
    try write(5_000, to: store.modelFolder.appending(path: "Encoder.mlmodelc/weights/weight.bin.partial"))
    try write(100, to: store.modelFolder.appending(path: "vocab.json"))

    #expect(store.isOnDevice == false)
  }

  /// The Parakeet check: every compiled model in the folder must be load-ready, whatever its name.
  @Test func allBundlesLoadReadyRejectsAnyHalfDownloadedBundle() throws {
    try writeBundle("Preprocessor.mlmodelc")
    #expect(ModelStore.allBundlesLoadReady(in: store.modelFolder))

    try write(10_000, to: store.modelFolder.appending(path: "Decoder.mlmodelc/weights/weight.bin"))

    #expect(ModelStore.allBundlesLoadReady(in: store.modelFolder) == false)
  }

  /// A plain file still downloading beside finished bundles (the vocabulary, say) is not ready either.
  @Test func allBundlesLoadReadyRejectsAPartialFileBesideTheBundles() throws {
    try writeBundle("Preprocessor.mlmodelc")
    try write(100, to: store.modelFolder.appending(path: "vocab.json.partial"))

    #expect(ModelStore.allBundlesLoadReady(in: store.modelFolder) == false)
  }

  /// An interrupted download: some files, not all. Not on the device, so nothing loads or downloads it by itself.
  @Test func aPartialDownloadIsNotOnDeviceButTakesSpace() throws {
    try write(10_000, to: store.modelFolder.appending(path: "Encoder.mlmodelc/weights.bin"))

    #expect(store.isOnDevice == false)
    #expect(store.bytes >= 10_000)
  }

  /// Another model's leftovers count towards the space but do not make this device's model present.
  @Test func anotherModelsFilesAreNotThisModel() throws {
    try write(10_000, to: downloads.appending(path: "parakeet/weights.bin"))

    #expect(store.isOnDevice == false)
    #expect(store.bytes >= 10_000)
  }

  @Test func theSizeCountsDownloadsAndTheCompiledCopy() throws {
    try write(100_000, to: store.modelFolder.appending(path: "weights.bin"))
    try write(50_000, to: compiled.appending(path: "bundle/model.bin"))

    #expect(store.bytes >= 150_000)
    #expect(store.bytes < 150_000 + 64 * 1024)  // allocation rounds each file up to a block
  }

  @Test func deleteRemovesTheDownloadsAndTheCompiledCopy() throws {
    try writeBundle("Encoder.mlmodelc")
    try write(100, to: store.modelFolder.appending(path: "vocab.json"))
    try write(50_000, to: compiled.appending(path: "bundle/model.bin"))

    try store.delete()

    #expect(store.isOnDevice == false)
    #expect(store.bytes == 0)
    #expect(FileManager.default.fileExists(atPath: downloads.path) == false)
    #expect(FileManager.default.fileExists(atPath: compiled.path) == false)
  }

  /// Each app sharing the folder compiles its own copy, so another app's first load, or the mark every app wrote
  /// before the folder could be shared, says nothing about this one's.
  @Test func onlyThisAppsMarkOfAFirstLoadCounts() throws {
    try write(0, to: store.modelFolder.appending(path: ".v2t-loaded-es.luischav.other"))
    try write(0, to: store.modelFolder.appending(path: ".v2t-loaded"))
    #expect(store.hasLoaded == false)

    store.markLoaded()

    #expect(store.hasLoaded)
  }

  @Test func deletingWhenNothingIsThereSucceeds() throws {
    try store.delete()

    #expect(store.bytes == 0)
  }
}
