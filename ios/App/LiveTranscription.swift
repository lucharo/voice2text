import Foundation
import os
import V2TPieces

let dictationLog = Logger(subsystem: "es.luischav.v2t", category: "dictation")

/// One dictation transcribed in pieces while it is recorded, so after Stop only the audio since the last cut is
/// left (#112), as the Mac app does. Every half second the audio recorded since the last look goes to a
/// `PieceTranscriber`, which decodes each settled piece of at most 14.9 s (one encoder window) at the
/// quietest moment near its 12 s mark. A dictation under 14.9 s is one decode at Stop, as before; a longer one
/// leaves only its last piece. Audio stays in memory on the phone.
@MainActor final class LiveTranscription {
  private let source: AudioSource
  private let pieces: PieceTranscriber
  private let isReady: () -> Bool
  private var fed = 0
  private var timer: Timer?
  private var feeding = false
  /// Called on the main actor with every piece's text each time a new piece is decoded while recording.
  var onPieces: (@MainActor ([String]) -> Void)?
  private var piecesSeen = 0
  /// Set at Stop: pieces decoded after it (the tail, by `finish`) are never offered for cleanup while recording.
  private var stopped = false

  /// `decode` is the speech model's call; `isReady` says whether it is loaded, since a piece is held back
  /// rather than sent to a model still loading.
  init(source: AudioSource, isReady: @escaping () -> Bool, decode: @escaping PieceTranscriber.Decode) {
    self.source = source
    self.isReady = isReady
    pieces = PieceTranscriber(decode: decode)
  }

  /// Starts looking at the recording every half second.
  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.feed() }
    }
  }

  /// Stops feeding; work already handed to the transcriber carries on, and `finish` picks up the rest.
  func stopFeeding() {
    stopped = true
    timer?.invalidate()
    timer = nil
  }

  /// The dictation was dropped (Cancel after Done, or the microphone session ended): stops feeding, no piece
  /// after the one being decoded now is decoded, and `finish` returns no text.
  func abandon() {
    stopFeeding()
    Task { await pieces.abandon() }
  }

  /// Hands the transcriber what was recorded since the last look. While it is still decoding a piece, the
  /// next tick takes the new audio instead, so ticks never pile up behind the model.
  func feed() {
    guard !feeding, isReady() else { return }
    let new = source.captured(from: fed)
    guard !new.isEmpty else { return }
    fed += new.count
    feeding = true
    Task {
      await pieces.add(new)
      feeding = false
      let texts = await pieces.pieceTexts
      if !stopped, texts.count > piecesSeen {  // a feed still running at Stop may read the tail's pieces
        piecesSeen = texts.count
        onPieces?(texts)
      }
    }
  }

  /// The text for the whole recording: decodes what the pieces have not covered, after any piece still being
  /// decoded, and logs how long that took and where the work ran (counts and times only, never text).
  func finish(_ recording: [Float], stoppedAt: ContinuousClock.Instant) async throws -> (text: String, report: PieceTranscriber.Report) {
    stopFeeding()
    let (text, report) = try await pieces.finish(recording)
    let ms = (ContinuousClock.now - stoppedAt) / .milliseconds(1)
    let seconds = Double(recording.count) / 16_000
    let detail = report.fellBack ? "a piece failed, whole recording" : "\(report.piecesWhileRecording) pieces while recording, \(report.piecesAtFinish) after"
    dictationLog.log("speech \(Int(ms), privacy: .public) ms after Stop for \(seconds, format: .fixed(precision: 1), privacy: .public) s of audio (\(detail, privacy: .public))")
    return (text, report)
  }
}
