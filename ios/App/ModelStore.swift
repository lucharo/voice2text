import Foundation

/// The speech model's files on the device: whether they are there, how much space they take, and deleting them.
/// FluidAudio keeps downloads under Application Support/FluidAudio/Models; Core ML keeps its compiled copy for the
/// Neural Engine in the app's Caches (com.apple.e5rt.e5bundlecache), which grows with every reinstall.
struct ModelStore: Sendable {
  /// The folder holding the downloaded files of the model this device uses.
  let modelFolder: URL
  /// Every folder that belongs to speech models (all downloads and the compiled copy), measured and deleted together.
  let folders: [URL]
  /// Whether `modelFolder` holds every file the model needs. A partial download is not on the device: only
  /// the user's Download finishes it, never a launch or a dictation.
  let isComplete: @Sendable (URL) -> Bool

  static func forDevice(modelFolder: URL, isComplete: @escaping @Sendable (URL) -> Bool) -> ModelStore {
    let bundle = Bundle.main.bundleIdentifier ?? "es.luischav.v2t"
    return ModelStore(modelFolder: modelFolder, folders: [
      URL.applicationSupportDirectory.appending(path: "FluidAudio/Models"),
      URL.cachesDirectory.appending(path: "\(bundle)/com.apple.e5rt.e5bundlecache"),
    ], isComplete: isComplete)
  }

  var isOnDevice: Bool { isComplete(modelFolder) }

  /// A file left in the model's folder once the model has loaded on this device, so a later launch knows the
  /// first load, which compiles the model for the Neural Engine, is done. Deleting the model removes it.
  var loadedMarker: URL { modelFolder.appending(path: ".v2t-loaded") }

  var hasLoaded: Bool { FileManager.default.fileExists(atPath: loadedMarker.path) }

  func markLoaded() { try? Data().write(to: loadedMarker) }

  /// Bytes the speech models take on the device, compiled copies and partial downloads included.
  var bytes: Int64 { folders.reduce(0) { $0 + Self.bytes(in: $1) } }

  /// True when every one of `names` is in `folder` and ready to load: a compiled model (`.mlmodelc`) needs its
  /// root `coremldata.bin` and no `*.partial` file from an interrupted download; a plain file must exist.
  /// FluidAudio's own rule at the pinned 55f65d9 (`ModelCache.incompleteFiles`, internal there).
  static func hasAll(_ names: [String], in folder: URL) -> Bool {
    names.allSatisfy { name in
      let path = folder.appending(path: name)
      guard name.hasSuffix(".mlmodelc") else { return FileManager.default.fileExists(atPath: path.path) }
      return isLoadReady(path)
    }
  }

  /// A compiled model folder with its root `coremldata.bin` and no `*.partial` staging file inside.
  static func isLoadReady(_ bundle: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: bundle.appending(path: "coremldata.bin").path) else { return false }
    return !hasPartialDownload(bundle)
  }

  /// True when an interrupted download left a `*.partial` file anywhere under `url`.
  static func hasPartialDownload(_ url: URL) -> Bool {
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
    for case let item as URL in walk where item.pathExtension == "partial" { return true }
    return false
  }

  /// Every compiled model directly in `folder` is ready to load (for a model whose file list FluidAudio keeps
  /// private, checked beside its own shallow `modelsExist`).
  static func allBundlesLoadReady(in folder: URL) -> Bool {
    guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
    return !hasPartialDownload(folder) && items.filter { $0.pathExtension == "mlmodelc" }.allSatisfy(isLoadReady)
  }

  func delete() throws {
    for f in folders where FileManager.default.fileExists(atPath: f.path) { try FileManager.default.removeItem(at: f) }
  }

  /// The size on disk of every file under `url`, 0 when it does not exist.
  static func bytes(in url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in walk {
      guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
      total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
    }
    return total
  }
}
