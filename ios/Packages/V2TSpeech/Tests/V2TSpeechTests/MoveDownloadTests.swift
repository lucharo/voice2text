import Foundation
import Testing
@testable import V2TSpeech

/// Moving a download made in the app's own folder into a shared one: whatever happens, the model is either
/// complete in one place or plainly not downloaded, never a half-moved folder that reads as complete.
@Suite(.serialized) struct MoveDownloadTests {
  let root = FileManager.default.temporaryDirectory.appending(path: "v2t-move-\(UUID().uuidString)")
  /// Two folders deep, as Nemotron's is (`nemotron-labs-unified-asr/coreml`).
  var old: URL { root.appending(path: "AppSupport/FluidAudio/Models/model/coreml") }
  var new: URL { root.appending(path: "Group/FluidAudio/Models/model/coreml") }
  let isComplete: (URL) -> Bool = { ModelStore.hasAll(["Encoder.mlmodelc", "vocab.json"], in: $0) }

  func write(_ bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: bytes).write(to: url)
  }

  /// A finished download, with a file of its own (`tag`) to tell the copies apart.
  func writeComplete(_ folder: URL, tag: String) throws {
    try write(10_000, to: folder.appending(path: "Encoder.mlmodelc/weights/weight.bin"))
    try write(100, to: folder.appending(path: "Encoder.mlmodelc/coremldata.bin"))
    try write(100, to: folder.appending(path: "vocab.json"))
    try write(1, to: folder.appending(path: tag))
  }

  /// Interrupted mid-weights: the encoder's coremldata.bin never arrived.
  func writePartial(_ folder: URL, tag: String) throws {
    try write(5_000, to: folder.appending(path: "Encoder.mlmodelc/weights/weight.bin.partial"))
    try write(1, to: folder.appending(path: tag))
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  @Test func nothingToMoveLeavesTheNewFolderAlone() throws {
    try writeComplete(new, tag: "new")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(isComplete(new))
    #expect(exists(new.appending(path: "new")))
    #expect(exists(old) == false)
  }

  @Test func aCompleteOldDownloadMovesWhenThereIsNoNewOne() throws {
    try writeComplete(old, tag: "old")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(isComplete(new))
    #expect(exists(new.appending(path: "old")))
    #expect(exists(old) == false)
  }

  /// The marks of a first load stay behind, this app's and the one every app wrote before: the next load may
  /// compile again at the new path.
  @Test func theOldMarksOfAFirstLoadDoNotMove() throws {
    try writeComplete(old, tag: "old")
    let store = ModelStore(modelFolder: old, folders: []) { _ in true }
    store.markLoaded()
    try write(0, to: old.appending(path: ".v2t-loaded"))

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    let moved = try FileManager.default.contentsOfDirectory(atPath: new.path).sorted()
    #expect(moved == ["Encoder.mlmodelc", "old", "vocab.json"])
  }

  /// Asked to move a folder onto itself (the caller named the default folder), it leaves the download alone.
  @Test func aFolderMovedOntoItselfStays() throws {
    try writeComplete(old, tag: "old")

    try ModelStore.moveDownload(from: old, to: old, isComplete: isComplete)

    #expect(isComplete(old))
    #expect(exists(old.appending(path: "old")))
  }

  /// Another app of the group downloaded the model first: its copy stays, the duplicate goes.
  @Test func aCompleteNewDownloadWinsOverTheOldOne() throws {
    try writeComplete(old, tag: "old")
    try writeComplete(new, tag: "new")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(isComplete(new))
    #expect(exists(new.appending(path: "new")))
    #expect(exists(old) == false)
  }

  @Test func aCompleteOldDownloadReplacesAPartialNewOne() throws {
    try writeComplete(old, tag: "old")
    try writePartial(new, tag: "new")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(isComplete(new))
    #expect(exists(new.appending(path: "old")))
    #expect(exists(new.appending(path: "new")) == false)
    #expect(exists(old) == false)
  }

  @Test func aPartialOldDownloadBesideANewOneIsThrownAway() throws {
    try writePartial(old, tag: "old")
    try writePartial(new, tag: "new")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(exists(new.appending(path: "new")))
    #expect(exists(old) == false)
  }

  /// A partial download moves as it is, still not complete, so the user's next Download resumes it there.
  @Test func aPartialOldDownloadMovesAsItIs() throws {
    try writePartial(old, tag: "old")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(isComplete(new) == false)
    #expect(exists(new.appending(path: "Encoder.mlmodelc/weights/weight.bin.partial")))
    #expect(exists(old) == false)
  }

  /// The partial new copy is thrown away, then the move itself fails (the old folder cannot be renamed out of
  /// its parent): the old download is still whole and complete, and nothing incomplete reads as complete. Run
  /// again once the folder can move, it finishes the job.
  @Test func aMoveThatFailsPartWayKeepsTheOldDownloadAndFinishesLater() throws {
    try writeComplete(old, tag: "old")
    try writePartial(new, tag: "new")
    let parent = old.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

    #expect(throws: (any Error).self) { try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete) }

    #expect(isComplete(old))
    #expect(exists(old.appending(path: "old")))
    #expect(exists(new) == false)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(isComplete(new))
    #expect(exists(old) == false)
  }

  /// A copy being thrown away when the app was killed: renamed, so FluidAudio never read it, and swept next time.
  @Test func whatAnInterruptedDiscardLeftIsSweptAway() throws {
    try writeComplete(new, tag: "new")
    let leftover = new.deletingLastPathComponent().appending(path: ".v2t-discarded-1234")
    try writeComplete(leftover, tag: "half-deleted")

    try ModelStore.moveDownload(from: old, to: new, isComplete: isComplete)

    #expect(exists(leftover) == false)
    #expect(isComplete(new))
  }
}
