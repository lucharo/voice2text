import Foundation

/// Transcribes one dictation piece by piece while it is recorded, so after Stop only the audio since the last
/// cut is left to decode (#112). Feed it the new audio as it arrives with `add`; each piece is decoded as soon
/// as `PieceCutter` knows its cut. `finish` takes the whole recording, decodes what is left and returns the
/// pieces' texts joined by spaces. A recording shorter than one piece plus its search is one decode at Stop,
/// exactly as before.
///
/// Work runs one step at a time in arrival order, so `finish` waits for a piece already being decoded and
/// never decodes the same audio twice. If decoding a piece fails, `finish` decodes the whole recording at once
/// instead, as the app did before pieces.
public actor PieceTranscriber {
  public typealias Decode = @Sendable ([Float]) async throws -> String

  /// What one dictation's decoding did, for the timing log.
  public struct Report: Sendable, Equatable {
    /// Pieces decoded before `finish` was called, while recording.
    public var piecesWhileRecording = 0
    /// Pieces decoded inside `finish`, the last one included.
    public var piecesAtFinish = 0
    /// True when a piece failed and `finish` decoded the whole recording instead.
    public var fellBack = false
  }

  private let cutter: PieceCutter
  private let minimumTail: Int
  private let decode: Decode
  private var pending: [Float] = []
  private var cutTotal = 0
  private var texts: [String] = []
  private var failed = false
  private var finished = false
  private var abandoned = false
  private var report = Report()
  private var pieceCount: Int { report.piecesWhileRecording + report.piecesAtFinish }
  private var last: Task<Void, Never>?

  /// `minimumTail`: a last piece shorter than this many samples is padded with silence to it. A recording can
  /// end a fraction of a second after a cut, and FluidAudio's Parakeet refuses anything under 0.3 s
  /// (`ASRConstants.minimumAudioDurationSeconds` at 55f65d9); its encoder pads every piece with silence to
  /// 15 s anyway.
  public init(cutter: PieceCutter = PieceCutter(), minimumTail: Int = 8_000, decode: @escaping Decode) {
    self.cutter = cutter
    self.minimumTail = minimumTail
    self.decode = decode
  }

  /// Samples received so far that were already decoded in pieces.
  public var decodedSamples: Int { cutTotal }

  /// The text of each piece decoded so far, in order (empty pieces left out), for cleanup while recording.
  public var pieceTexts: [String] { texts }

  /// Appends newly recorded audio and decodes every piece whose cut is now known. Returns once that is done.
  public func add(_ samples: [Float]) async {
    await enqueue { me in await me.append(samples) }
  }

  /// The whole recording (it must begin with everything given to `add`): decodes what the pieces have not
  /// covered and returns the full text with a report of what ran where.
  public func finish(_ recording: [Float]) async throws -> (text: String, report: Report) {
    try await enqueue { me in await me.complete(recording) }.get()
  }

  /// Drops the dictation: no piece after the one being decoded now is decoded, and `finish` throws
  /// `CancellationError` instead of returning text, also when it is already under way. Takes effect at once,
  /// not after queued work, since it is not queued.
  public func abandon() {
    abandoned = true
  }

  // MARK: steps, run one at a time by `enqueue`

  private func append(_ samples: [Float]) async {
    guard !finished, !failed, !abandoned else { return }
    pending += samples
    await decodeSettled(atFinish: false)
  }

  private func complete(_ recording: [Float]) async -> Result<(String, Report), Error> {
    finished = true
    if !failed, !abandoned, recording.count >= cutTotal {
      pending = Array(recording[cutTotal...])
      await decodeSettled(atFinish: true)
      if !failed, !abandoned {
        if !pending.isEmpty {
          let padding = pieceCount > 0 ? max(0, minimumTail - pending.count) : 0
          await decodePiece(pending.count, atFinish: true, padding: padding)
        }
        if !failed, !abandoned { return .success((texts.joined(separator: " "), report)) }
      }
    }
    // dropped (Cancel, or the microphone session ended) while waiting or decoding: nothing more is decoded,
    // not the tail and not the whole recording again, and no text comes back to be typed or kept
    if abandoned { return .failure(CancellationError()) }
    report.fellBack = true
    let whole: Result<String, Error>
    do { whole = .success(try await decode(recording).trimmed) } catch { whole = .failure(error) }
    // dropped while the whole recording was decoding: its text is not returned either
    if abandoned { return .failure(CancellationError()) }
    return whole.map { ($0, report) }
  }

  private func decodeSettled(atFinish: Bool) async {
    while !failed, !abandoned, let cut = cutter.cut(pending[...]) {
      await decodePiece(cut, atFinish: atFinish)
    }
  }

  /// Decodes the first `cut` pending samples, followed by `padding` samples of silence.
  private func decodePiece(_ cut: Int, atFinish: Bool, padding: Int = 0) async {
    do {
      let text = try await decode(Array(pending[..<cut]) + [Float](repeating: 0, count: padding)).trimmed
      if !text.isEmpty { texts.append(text) }
      pending.removeFirst(cut)
      cutTotal += cut
      if atFinish { report.piecesAtFinish += 1 } else { report.piecesWhileRecording += 1 }
    } catch {
      failed = true
      pending = []
    }
  }

  /// Runs `step` after every step queued before it and returns its result.
  @discardableResult
  private func enqueue<T: Sendable>(_ step: @escaping @Sendable (isolated PieceTranscriber) async -> T) async -> T {
    let previous = last
    let task = Task<T, Never> {
      await previous?.value
      return await step(self)
    }
    last = Task { _ = await task.value }
    return await task.value
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
