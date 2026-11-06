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

  /// Bytes the speech models take on the device, compiled copies and partial downloads included.
  var bytes: Int64 { folders.reduce(0) { $0 + Self.bytes(in: $1) } }

  /// True when every one of `names` is in `folder` (a file, or a compiled model folder).
  static func hasAll(_ names: [String], in folder: URL) -> Bool {
    names.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
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
