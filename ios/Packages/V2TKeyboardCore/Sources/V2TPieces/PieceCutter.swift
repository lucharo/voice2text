/// Where to cut a dictation that is still being recorded, so the part already spoken can be transcribed while
/// the user keeps talking (#112). The rule is the Mac's `PieceDecoder` (v2t/backends.py): each piece ends at
/// the quietest `quiet` seconds within `search` seconds of its `piece`-second mark, so no word is cut in half,
/// and a cut is known `search` seconds after its mark.
///
/// The defaults keep every piece inside one encoder window: FluidAudio's Parakeet v3 decodes up to 240,000
/// samples (15 s) in one window and Nemotron Unified up to 239,360 (187 frames of 1,280), and a piece within one
/// window is decoded exactly as a whole recording of that length would be. 12 s pieces are the Mac's Core ML
/// setting (v2t/coreml.py); its 3 s search is 2.9 s here so the longest piece, 14.9 s, fits Nemotron's window.
public struct PieceCutter: Sendable, Equatable {
  public let piece: Int
  public let search: Int
  public let window: Int

  public init(sampleRate: Int = 16_000, pieceSeconds: Double = 12, searchSeconds: Double = 2.9, quietSeconds: Double = 0.1) {
    piece = Int((Double(sampleRate) * pieceSeconds).rounded())
    search = Int((Double(sampleRate) * searchSeconds).rounded())
    window = max(1, Int((Double(sampleRate) * quietSeconds).rounded()))
    precondition(search * 2 >= window && search <= piece, "the search region must hold one quiet window and start after 0")
  }

  /// The longest piece this cutter makes, in samples.
  public var longestPiece: Int { piece + search }

  /// Where to cut `pending`, the audio after the last cut: the middle of its quietest `window` samples in
  /// [piece − search, piece + search), the earliest one on a tie. Nil until that whole region has arrived.
  public func cut(_ pending: ArraySlice<Float>) -> Int? {
    guard pending.count >= piece + search else { return nil }
    let lo = pending.startIndex + piece - search
    let n = 2 * search
    // running sum of squares over `window` samples, so the scan is linear in the region
    var sum = 0.0
    func energy(_ x: Float) -> Double { Double(x) * Double(x) }
    for i in lo..<(lo + window) { sum += energy(pending[i]) }
    var best = sum, bestAt = 0
    var at = 1
    while at + window <= n {
      let out = pending[lo + at - 1], into = pending[lo + at + window - 1]
      sum += energy(into) - energy(out)
      // a later window must be clearly quieter, so rounding in the running sum never breaks a tie
      if sum < best - 1e-9 * max(1, best) { best = sum; bestAt = at }
      at += 1
    }
    return piece - search + bestAt + window / 2
  }
}
