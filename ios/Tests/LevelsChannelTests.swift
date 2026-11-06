import Foundation
import Testing
@testable import V2T

/// The waveform's levels file: the app rewrites it 20 times a second while the keyboard reads it 30 times a
/// second from another process, so a read must never see a half-written file.
struct LevelsChannelTests {
  let file = FileManager.default.temporaryDirectory.appending(path: "v2t-levels-\(UUID().uuidString).bin")

  @Test func readsBackWhatWasWritten() {
    DictationChannel.writeLevels([0.25, 0.5, 1], to: file)

    #expect(DictationChannel.readLevels(from: file) == [0.25, 0.5, 1])
  }

  @Test func aMissingFileReadsAsNoReadingRatherThanSilence() {
    #expect(DictationChannel.readLevels(from: file) == nil)
  }

  /// A writer and a reader racing, as the app and the keyboard do: every read is a whole list the writer wrote.
  @Test func aReadDuringARewriteSeesTheWholeOldOrNewList() async {
    let full = [Float](repeating: 0.5, count: 96)
    DictationChannel.writeLevels(full, to: file)
    let url = file
    let writer = Task.detached {
      for i in 0..<3_000 { DictationChannel.writeLevels([Float](repeating: Float(i % 7) / 7, count: 96), to: url) }
    }
    var torn = 0, reads = 0
    while reads < 3_000 {
      let got = DictationChannel.readLevels(from: url)
      reads += 1
      if got?.count != 96 { torn += 1 }
    }
    await writer.value

    #expect(torn == 0, "\(torn) of \(reads) reads saw a missing, empty or partial file")
  }
}
