import Foundation
import Testing
@testable import V2T

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
    try write(10_000, to: store.modelFolder.appending(path: "Encoder.mlmodelc/weights.bin"))
    try write(100, to: store.modelFolder.appending(path: "vocab.json"))

    #expect(store.isOnDevice)
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
    try write(100_000, to: store.modelFolder.appending(path: "Encoder.mlmodelc/weights.bin"))
    try write(100, to: store.modelFolder.appending(path: "vocab.json"))
    try write(50_000, to: compiled.appending(path: "bundle/model.bin"))

    try store.delete()

    #expect(store.isOnDevice == false)
    #expect(store.bytes == 0)
    #expect(FileManager.default.fileExists(atPath: downloads.path) == false)
    #expect(FileManager.default.fileExists(atPath: compiled.path) == false)
  }

  @Test func deletingWhenNothingIsThereSucceeds() throws {
    try store.delete()

    #expect(store.bytes == 0)
  }
}
