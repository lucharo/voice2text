import CoreGraphics
import Foundation

/// Presentation mode for the dictation controls on the keyboard.
public enum RecordingPresentation: Equatable, Sendable {
  /// Compact 44 pt bar replacing the suggestion bar while keeping the keys interactive.
  case compact
  /// Full-height recording overlay covering the keys with large controls and waveform.
  case expanded
}

/// Visual state for the bottom-row microphone key.
public enum MicKeyVisual: Equatable, Sendable {
  case idle
  case listening
  case busy
}

/// How a finished dictation transcript should be delivered to the document.
public enum TranscriptDelivery: Equatable, Sendable {
  case insertImmediately(String)
  case offerBanner(String)
}

/// Pure state machine governing the collapsible recording bar, key click muting, and safe transcript delivery
/// when the user edits text while waiting for transcription.
public struct RecordingUIState: Equatable, Sendable {
  public private(set) var presentation: RecordingPresentation = .compact
  public private(set) var active = false
  public private(set) var listening = false
  public private(set) var typedWhileWaiting = false
  public private(set) var pendingTranscript: String?

  public init() {}

  public var showsCompactBar: Bool { active && presentation == .compact }
  public var showsExpandedPanel: Bool { active && presentation == .expanded }
  public var hidesKeyboard: Bool { showsExpandedPanel }
  public var hidesSuggestionBar: Bool { active }
  public var mutesKeyClicks: Bool { active && listening }
  public var isModal: Bool { showsExpandedPanel }
  public var micKeyVisual: MicKeyVisual { !active ? .idle : (listening ? .listening : .busy) }

  /// Syncs active/listening state from `DictationState`. Preserves presentation across `.listening -> .transcribing`,
  /// resets presentation to `.compact` on session start or end, and retains `typedWhileWaiting` across an
  /// active -> idle transition so an immediately following `receiveTranscript` still sees it.
  public mutating func update(active newActive: Bool, listening newListening: Bool) {
    if !active && newActive {
      presentation = .compact
      typedWhileWaiting = false
      pendingTranscript = nil
    } else if active && !newActive {
      presentation = .compact
    } else if listening && !newListening {
      typedWhileWaiting = false
    }
    active = newActive
    listening = newListening
  }

  public mutating func expand() {
    if active { presentation = .expanded }
  }

  public mutating func collapse() {
    if active { presentation = .compact }
  }

  public mutating func togglePresentation() {
    if active { presentation = presentation == .compact ? .expanded : .compact }
  }

  /// Records a user edit (typing, delete, swipe, suggestion pick, or cursor move).
  /// Typing while listening is normal and does not block auto-insertion; typing while transcribing defers to a banner.
  public mutating func noteUserTyped() {
    if active && !listening { typedWhileWaiting = true }
  }

  public mutating func receiveTranscript(_ text: String) -> TranscriptDelivery {
    let wasWaitingTyped = typedWhileWaiting
    typedWhileWaiting = false
    if wasWaitingTyped {
      pendingTranscript = text
      return .offerBanner(text)
    }
    pendingTranscript = nil
    return .insertImmediately(text)
  }

  public mutating func acceptPendingTranscript() -> String? {
    defer { pendingTranscript = nil }
    return pendingTranscript
  }

  public mutating func dismissPendingTranscript() {
    pendingTranscript = nil
  }
}

/// Non-overlapping frames for the 44 pt compact recording bar across phone and iPad widths.
public struct CompactBarGeometry: Equatable, Sendable {
  public let cancel: CGRect
  public let dot: CGRect
  public let spinner: CGRect
  public let status: CGRect
  public let mic: CGRect
  public let wave: CGRect
  public let expandButton: CGRect
  public let expandHitArea: CGRect
  public let done: CGRect

  public static func compute(
    size: CGSize,
    listening: Bool,
    statusSize: CGSize,
    micSize: CGSize,
    hasMic: Bool,
    doneWidth: CGFloat
  ) -> CompactBarGeometry {
    guard size.width > 0, size.height > 0 else {
      return CompactBarGeometry(
        cancel: .zero, dot: .zero, spinner: .zero, status: .zero, mic: .zero,
        wave: .zero, expandButton: .zero, expandHitArea: .zero, done: .zero)
    }

    let pad: CGFloat = 6
    let gap: CGFloat = 6
    let cancelSide: CGFloat = min(32, size.height - 4)
    let cancel = CGRect(x: pad, y: (size.height - cancelSide) / 2, width: cancelSide, height: cancelSide)

    if !listening {
      let expandW: CGFloat = 32
      let expandButton = CGRect(x: max(cancel.maxX + gap, size.width - pad - expandW), y: 0, width: expandW, height: size.height)
      let spinSide: CGFloat = 20
      let spinner = CGRect(x: cancel.maxX + 10, y: (size.height - spinSide) / 2, width: spinSide, height: spinSide)
      let statusX = spinner.maxX + 6
      let statusMaxW = max(0, expandButton.minX - 6 - statusX)
      let statusW = min(statusSize.width, statusMaxW)
      let statusH = min(size.height, max(18, statusSize.height))
      let status = CGRect(x: statusX, y: (size.height - statusH) / 2, width: statusW, height: statusH)
      let hitW = max(0, expandButton.maxX - spinner.minX)
      let expandHitArea = CGRect(x: spinner.minX, y: 0, width: hitW, height: size.height)
      return CompactBarGeometry(
        cancel: cancel, dot: .zero, spinner: spinner, status: status, mic: .zero,
        wave: .zero, expandButton: expandButton, expandHitArea: expandHitArea, done: .zero)
    }

    let doneW = max(68, doneWidth)
    let doneH: CGFloat = min(32, size.height - 4)
    let done = CGRect(x: size.width - pad - doneW, y: (size.height - doneH) / 2, width: doneW, height: doneH)

    let expandW: CGFloat = 30
    let expandButton = CGRect(x: max(cancel.maxX + gap, done.minX - 2 - expandW), y: 0, width: expandW, height: size.height)

    let left = cancel.maxX + gap
    let right = max(left, expandButton.minX - 4)
    let avail = max(0, right - left)

    let dotSide: CGFloat = 7
    let dotGap: CGFloat = 5
    let waveGap: CGFloat = 8
    let minWave: CGFloat = avail >= 140 ? 48 : max(0, avail - 92)
    let infoMaxW = max(0, avail - minWave - waveGap)

    let statusW = min(statusSize.width, max(0, infoMaxW - dotSide - dotGap))
    let statusH = max(16, statusSize.height)
    let micH = hasMic ? max(13, micSize.height) : 0
    let micW = hasMic ? min(micSize.width, infoMaxW) : 0

    let dot: CGRect
    let status: CGRect
    let mic: CGRect
    if hasMic {
      let lineGap: CGFloat = 1
      let totalH = statusH + lineGap + micH
      let topY = max(2, (size.height - totalH) / 2)
      dot = CGRect(x: left, y: topY + (statusH - dotSide) / 2, width: dotSide, height: dotSide)
      status = CGRect(x: dot.maxX + dotGap, y: topY, width: statusW, height: statusH)
      mic = CGRect(x: left, y: topY + statusH + lineGap, width: micW, height: micH)
    } else {
      let topY = (size.height - statusH) / 2
      dot = CGRect(x: left, y: (size.height - dotSide) / 2, width: dotSide, height: dotSide)
      status = CGRect(x: dot.maxX + dotGap, y: topY, width: statusW, height: statusH)
      mic = .zero
    }

    let infoRight = max(status.maxX, hasMic ? mic.maxX : status.maxX)
    let waveX = infoRight + waveGap
    let waveW = max(0, right - waveX)
    let waveH = min(24, max(0, size.height - 12))
    let wave = CGRect(x: waveX, y: (size.height - waveH) / 2, width: waveW, height: waveH)
    let expandHitArea = CGRect(x: left, y: 0, width: max(0, expandButton.maxX - left), height: size.height)

    return CompactBarGeometry(
      cancel: cancel, dot: dot, spinner: .zero, status: status, mic: mic,
      wave: wave, expandButton: expandButton, expandHitArea: expandHitArea, done: done)
  }
}
