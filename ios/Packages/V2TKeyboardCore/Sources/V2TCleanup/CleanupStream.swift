// Cleanup while the dictation is still being recorded: decides which settled text may be cleaned now, so after
// Stop only the rest is left. Standard library only, like the rest of V2TCleanup; the app does the model calls.

/// Which part of a dictation transcribed in pieces may be cleaned before Stop, and what is left after it.
///
/// A segment is taken once the settled text after the last segment holds at least `minimumWords` words and
/// reaches a sentence end *inside* a piece. A sentence end at a piece's own end does not count: the speech model
/// often closes a piece with a full stop where the cut fell mid-sentence (#126: 71 to 262 extra sentence ends in
/// 1,452 cuts), and cleanup is what repairs that, so it must see both sides of the cut. Each segment is then
/// cleaned on its own, through the same chunking and guards as a whole dictation.
public struct CleanupStream: Sendable {
  public let minimumWords: Int
  /// Words handed out so far, as `next` split them; the text after Stop must begin with them.
  private var taken: [Substring] = []

  public init(minimumWords: Int = 30) { self.minimumWords = minimumWords }

  /// Number of words already handed out for cleaning.
  public var takenWords: Int { taken.count }

  /// The next segment to clean, given the texts of every piece transcribed so far, or nil when there is not yet
  /// enough settled text ending at a sentence end inside a piece.
  public mutating func next(pieces: [String]) -> String? {
    var words: [Substring] = []
    var pieceEnds = Set<Int>()  // word counts at which a piece ends
    for piece in pieces {
      words += piece.split(whereSeparator: \.isWhitespace)
      pieceEnds.insert(words.count)
    }
    guard words.count > taken.count, Array(words[..<taken.count]) == taken else { return nil }
    var end = words.count
    while end > taken.count {
      if !pieceEnds.contains(end), let last = words[end - 1].unicodeScalars.last, Self.sentenceEnds.contains(last) { break }
      end -= 1
    }
    guard end - taken.count >= minimumWords else { return nil }
    let segment = words[taken.count..<end]
    taken += segment
    return segment.joined(separator: " ")
  }

  /// What is left to clean in the dictation's final text, or nil when that text does not begin with the
  /// segments handed out (the speech model re-decoded the whole recording), in which case clean all of it.
  public func rest(of text: String) -> String? {
    let words = text.split(whereSeparator: \.isWhitespace)
    guard words.count >= taken.count, Array(words[..<taken.count]) == taken else { return nil }
    return words[taken.count...].joined(separator: " ")
  }

  private static let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?", "…"]
}
