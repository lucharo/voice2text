import Foundation
import Testing

/// The repository's root Package.swift, through which other apps depend on V2TSpeech by git URL, builds this
/// package's sources against the same FluidAudio as the v2t app.
struct ManifestTests {
  let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  var repository: URL { package.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

  func fluidAudioRevisions(in manifest: URL) throws -> [String] {
    let text = try String(contentsOf: manifest, encoding: .utf8)
    return text.matches(of: /FluidInference\/FluidAudio", revision: "([0-9a-f]{40})"/).map { String($0.1) }
  }

  @Test func theRootManifestPinsTheSameFluidAudio() throws {
    let root = try fluidAudioRevisions(in: repository.appending(path: "Package.swift"))
    let own = try fluidAudioRevisions(in: package.appending(path: "Package.swift"))

    #expect(own.count == 1)
    #expect(root == own)
  }

  @Test func theRootManifestBuildsThisPackagesSources() throws {
    let text = try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
    let paths = text.matches(of: /path: "([^"]+)"/).map { String($0.1) }

    #expect(paths == ["ios/Packages/V2TSpeech/Sources/V2TSpeech"])
  }
}
