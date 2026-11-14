import Foundation
import Testing
@testable import V2T

/// v2t keeps the speech model where another app of the App Group can load it: FluidAudio/Models in the group's
/// container, the folder `SpeechEngine.modelsDirectory(appGroup:)` names for any app of the group.
@MainActor struct ModelsFolderTests {
  @Test func theModelLivesInTheAppGroupsContainer() throws {
    let group = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.es.luischav.v2t"))

    let models = DictationService.modelsDirectory(for: .parakeet)

    #expect(models?.path == group.appending(path: "FluidAudio/Models").path)
  }
}
