import FluidAudio
import Testing
@testable import V2T

struct SpeechEngineTests {
  @Test func aCachedModelNeverShowsAsDownloading() {
    // FluidAudio's cached fast path reports a download of zero files at the download weight
    let cached = DownloadProgress(fractionCompleted: 0.5, phase: .downloading(completedFiles: 0, totalFiles: 0))
    #expect(SpeechEngine.state(for: cached) == .loading)
    #expect(SpeechEngine.state(for: .init(fractionCompleted: 0.75, phase: .compiling(modelName: "Encoder"))) == .loading)
  }

  @Test func theBarShowsTheDownloadAlone() {
    #expect(SpeechEngine.state(for: .init(fractionCompleted: 0, phase: .listing)) == .downloading(0))
    #expect(SpeechEngine.state(for: .init(fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4))) == .downloading(0.5))
    #expect(SpeechEngine.state(for: .init(fractionCompleted: 0.5, phase: .downloading(completedFiles: 4, totalFiles: 4))) == .downloading(1))
  }
}
