import Foundation

/// The speech model's files on the device: whether they are there, how much space they take, and deleting them.
/// FluidAudio keeps downloads in a models folder (by default Application Support/FluidAudio/Models; an App Group's
/// container when the apps of the group share them); Core ML keeps its compiled copy for the Neural Engine in each
/// app's own Caches (com.apple.e5rt.e5bundlecache), which grows with every reinstall.
public struct ModelStore: Sendable {
  /// The folder holding the downloaded files of the model this device uses.
  public let modelFolder: URL
  /// Every folder that belongs to speech models (all downloads and the compiled copy), measured and deleted together.
  public let folders: [URL]
  /// Whether `modelFolder` holds every file the model needs. A partial download is not on the device: only
  /// the user's Download finishes it, never a launch or a dictation.
  public let isComplete: @Sendable (URL) -> Bool

  public init(modelFolder: URL, folders: [URL], isComplete: @escaping @Sendable (URL) -> Bool) {
    self.modelFolder = modelFolder
    self.folders = folders
    self.isComplete = isComplete
  }

  /// The files of `model` in `modelsDirectory`, the folder given to `SpeechEngine(speech:modelsDirectory:)`; nil
  /// for FluidAudio's default in this app. Measured and deleted with them: everything else in that folder, this
  /// app's own FluidAudio folder when that is another one (a download made before the model moved), and this
  /// app's compiled copy.
  public static func forDevice(_ model: SpeechEngine.Model, modelsDirectory: URL? = nil) -> ModelStore {
    let bundle = Bundle.main.bundleIdentifier ?? "es.luischav.v2t"
    let own = SpeechEngine.defaultModelsDirectory, models = modelsDirectory ?? own
    let downloads = models.standardizedFileURL.path == own.standardizedFileURL.path ? [own] : [models, own]
    return ModelStore(modelFolder: SpeechEngine.modelFolder(for: model, in: modelsDirectory), folders: downloads + [
      URL.cachesDirectory.appending(path: "\(bundle)/com.apple.e5rt.e5bundlecache"),
    ], isComplete: SpeechEngine.isComplete(model))
  }

  public var isOnDevice: Bool { isComplete(modelFolder) }

  /// A file left in the model's folder once the model has loaded in this app, so a later launch knows the first
  /// load, which compiles the model for the Neural Engine into the app's own Caches, is done. Named after the app:
  /// another app sharing the folder has a compiled copy of its own. Deleting the model removes it.
  public var loadedMarker: URL {
    modelFolder.appending(path: "\(Self.loadedMarkerPrefix)-\(Bundle.main.bundleIdentifier ?? "es.luischav.v2t")")
  }

  /// Every app's mark starts so, and so did the one mark all apps wrote before the folder could be shared.
  static let loadedMarkerPrefix = ".v2t-loaded"

  public var hasLoaded: Bool { FileManager.default.fileExists(atPath: loadedMarker.path) }

  public func markLoaded() { try? Data().write(to: loadedMarker) }

  /// Bytes the speech models take on the device, compiled copies and partial downloads included.
  public var bytes: Int64 { folders.reduce(0) { $0 + Self.bytes(in: $1) } }

  /// True when every one of `names` is in `folder` and ready to load: a compiled model (`.mlmodelc`) needs its
  /// root `coremldata.bin` and no `*.partial` file from an interrupted download; a plain file must exist.
  /// FluidAudio's own rule at the pinned 55f65d9 (`ModelCache.incompleteFiles`, internal there).
  public static func hasAll(_ names: [String], in folder: URL) -> Bool {
    names.allSatisfy { name in
      let path = folder.appending(path: name)
      guard name.hasSuffix(".mlmodelc") else { return FileManager.default.fileExists(atPath: path.path) }
      return isLoadReady(path)
    }
  }

  /// A compiled model folder with its root `coremldata.bin` and no `*.partial` staging file inside.
  public static func isLoadReady(_ bundle: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: bundle.appending(path: "coremldata.bin").path) else { return false }
    return !hasPartialDownload(bundle)
  }

  /// True when an interrupted download left a `*.partial` file anywhere under `url`.
  public static func hasPartialDownload(_ url: URL) -> Bool {
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
    for case let item as URL in walk where item.pathExtension == "partial" { return true }
    return false
  }

  /// Every compiled model directly in `folder` is ready to load (for a model whose file list FluidAudio keeps
  /// private, checked beside its own shallow `modelsExist`).
  public static func allBundlesLoadReady(in folder: URL) -> Bool {
    guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
    return !hasPartialDownload(folder) && items.filter { $0.pathExtension == "mlmodelc" }.allSatisfy(isLoadReady)
  }

  /// Moves a model folder from `old` to `new` (another models folder), keeping whichever copy is complete: the
  /// old one when nothing is at `new` yet, complete or not (a partial download resumes there); the new one when it
  /// is complete or the old one is not. Each step renames within one volume, so an interruption leaves each folder
  /// whole, and a copy thrown away is renamed out of FluidAudio's sight before it is deleted, so a half-deleted
  /// folder never reads as complete. Run it again after a failure or an interruption: it carries on.
  public static func moveDownload(from old: URL, to new: URL, isComplete: (URL) -> Bool) throws {
    let fm = FileManager.default
    for folder in [old, new] { sweepDiscarded(beside: folder) }
    guard fm.fileExists(atPath: old.path), old.standardizedFileURL.path != new.standardizedFileURL.path else { return }
    if fm.fileExists(atPath: new.path) {
      if isComplete(new) || !isComplete(old) { return try discard(old) }
      try discard(new)
    }
    // whether Core ML reuses the compiled copy at the new path is unknown, so the next load counts as a first one
    // again: the marks of a first load go before the move, so an interruption cannot carry one across
    let items = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
    for item in items where item.lastPathComponent.hasPrefix(loadedMarkerPrefix) { try fm.removeItem(at: item) }
    try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: old, to: new)
  }

  static let discardedPrefix = ".v2t-discarded-"

  /// Renames `folder` to a name FluidAudio never reads, then deletes it.
  static func discard(_ folder: URL) throws {
    let trash = folder.deletingLastPathComponent().appending(path: discardedPrefix + UUID().uuidString)
    try FileManager.default.moveItem(at: folder, to: trash)
    try FileManager.default.removeItem(at: trash)
  }

  /// Deletes what an interrupted `discard` left beside `folder`.
  static func sweepDiscarded(beside folder: URL) {
    let parent = folder.deletingLastPathComponent()
    let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
    for item in items where item.lastPathComponent.hasPrefix(discardedPrefix) { try? FileManager.default.removeItem(at: item) }
  }

  public func delete() throws {
    for f in folders where FileManager.default.fileExists(atPath: f.path) { try FileManager.default.removeItem(at: f) }
  }

  /// The size on disk of every file under `url`, 0 when it does not exist.
  public static func bytes(in url: URL) -> Int64 {
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
