import UIKit

/// What the keyboard shows while it records and transcribes, in place of the keys: a live waveform of the
/// microphone, then Cancel (drop the recording) and Done (type it) where the bottom row of keys was.
final class RecordingPanel: UIView {
  var onStop: (() -> Void)?
  var onCancel: (() -> Void)?
  /// Reads the dictation state now; checked once a second while the panel is up.
  var liveState: (() -> DictationState?)?
  /// The state read through liveState changed without a notification (the app quit or crashed).
  var onStateChange: ((DictationState) -> Void)?
  /// The control VoiceOver lands on when the panel appears.
  var focusTarget: UIView { state == .listening ? done : status }

  private let wave = CAShapeLayer()
  private let status = UILabel()
  /// The microphone the app records from, top right while listening ("iPhone Microphone", "AirPods Pro").
  private let mic = UILabel()
  private var shownMicrophone: Microphone?
  private let dot = UIView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let cancel = UIButton(type: .system)
  private let done = UIButton(type: .system)
  private var timer: Timer?
  private var started = Date()
  /// When Done was tapped (or the wait was first shown): the wait after it ticks from here, and the
  /// controller reads it once the text is in, for "Done in 1.4 s".
  private(set) var stoppedAt: Date?
  private var levels: [Float] = []
  private(set) var state: DictationState = .idle
  private var ticks = 0
  /// The bottom row of keys, in this view's coordinates, so the controls sit where the keys were.
  private var bottomRow: CGRect = .zero
  /// UI tests: a made-up waveform instead of the app's levels file.
  var preview = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear  // the keyboard's glass, as behind the keys (the controller hides the keys)
    wave.fillColor = UIColor.label.cgColor
    layer.addSublayer(wave)
    status.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    status.textColor = .secondaryLabel
    status.accessibilityIdentifier = "v2t.recording.status"
    mic.font = .systemFont(ofSize: 13, weight: .medium)
    mic.textColor = .secondaryLabel
    mic.lineBreakMode = .byTruncatingTail
    mic.accessibilityIdentifier = "v2t.recording.mic"
    dot.backgroundColor = .systemRed
    dot.layer.cornerRadius = 4
    spinner.hidesWhenStopped = true
    for v in [status, mic, dot, spinner, cancel, done] as [UIView] { addSubview(v) }

    done.configuration = Self.filled(title: "Done", symbol: "checkmark", color: .systemBlue)
    done.accessibilityIdentifier = "v2t.recording.done"
    done.addAction(UIAction { [weak self] _ in
      self?.stoppedAt = Date()  // the tap itself, before the app hears of it
      self?.onStop?()
    }, for: .touchUpInside)
    var c = UIButton.Configuration.filled()
    c.title = "Cancel"
    c.baseBackgroundColor = Palette.key
    c.baseForegroundColor = .label
    c.cornerStyle = .large
    c.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: 18, weight: .medium); return a }
    cancel.configuration = c
    cancel.accessibilityIdentifier = "v2t.recording.cancel"
    cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private static func filled(title: String, symbol: String, color: UIColor) -> UIButton.Configuration {
    var c = UIButton.Configuration.filled()
    c.title = title
    c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    c.imagePadding = 8
    c.baseBackgroundColor = color
    c.baseForegroundColor = .white
    c.cornerStyle = .capsule
    c.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: 19, weight: .semibold); return a }
    return c
  }

  /// Shows the panel for `state`, with its buttons laid over the keyboard's `bottomRow`.
  func show(_ state: DictationState, bottomRow: CGRect) {
    if isHidden || state != self.state { started = state == .listening ? Date() : started }
    // a new recording forgets the last wait; Done's own tap re-shows .listening and must keep its time
    if state == .listening, isHidden || self.state != .listening { stoppedAt = nil }
    if state != .listening, stoppedAt == nil { stoppedAt = Date() }
    self.state = state
    self.bottomRow = bottomRow
    isHidden = false
    let listening = state == .listening
    cancel.isHidden = !listening
    done.isHidden = !listening
    dot.isHidden = !listening
    mic.isHidden = !listening
    refreshMicrophone()
    if listening { spinner.stopAnimating() } else { spinner.startAnimating() }
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
    }
    tick()
    setNeedsLayout()
  }

  func hide() {
    isHidden = true
    stoppedAt = nil  // the controller took it before hiding; a later wait (the app hand-off) starts afresh
    timer?.invalidate()
    timer = nil
    levels = []
    state = .idle
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side: CGFloat = 12
    status.sizeToFit()
    dot.frame = CGRect(x: side + 4, y: 18, width: 8, height: 8)
    status.frame.origin = CGPoint(x: dot.isHidden ? side + 4 : dot.frame.maxX + 6, y: 22 - status.frame.height / 2)
    mic.sizeToFit()
    let micWidth = min(mic.frame.width, bounds.width - status.frame.maxX - 2 * side - 8)
    mic.frame = CGRect(x: bounds.maxX - side - 4 - micWidth, y: 22 - mic.frame.height / 2, width: max(0, micWidth), height: mic.frame.height)
    spinner.center = CGPoint(x: bounds.midX, y: (bottomRow.minY > 0 ? bottomRow.midY : bounds.maxY - 30))
    let row = bottomRow.height > 0 ? bottomRow : CGRect(x: 3, y: bounds.maxY - 50, width: bounds.width - 6, height: 42)
    let cw = (row.width - 2 * side) * 0.32
    cancel.frame = CGRect(x: row.minX + side, y: row.minY - 3, width: cw, height: row.height + 6)
    done.frame = CGRect(x: cancel.frame.maxX + 10, y: row.minY - 3, width: row.maxX - side - cancel.frame.maxX - 10, height: row.height + 6)
    drawWave()
  }

  private func tick() {
    ticks += 1
    if !preview, ticks % 30 == 0, let live = liveState?(), live != state {
      onStateChange?(live)
      return
    }
    if ticks % 30 == 0 { refreshMicrophone() }  // the input can change mid-dictation (a headset plugged in)
    if state == .listening {
      if preview { levels = Self.fakeLevels(Date().timeIntervalSince(started)) } else if let read = DictationChannel.readLevels() { levels = read }
      let s = Int(Date().timeIntervalSince(started))
      status.text = String(format: "%d:%02d", s / 60, s % 60)
      status.accessibilityLabel = nil
      status.accessibilityValue = nil
    } else {
      let elapsed = Date().timeIntervalSince(stoppedAt ?? Date())
      status.text = state.waitingLabel(elapsed: elapsed)
      // VoiceOver gets the stage as the label and the time as the value, read when it lands there
      status.accessibilityLabel = state.waitingLabel
      status.accessibilityValue = DictationState.seconds(elapsed, locale: .current)
    }
    setNeedsLayout()
  }

  /// Shows the app's microphone as a mic icon and its name; hidden when the app has not said which.
  private func refreshMicrophone() {
    let now = preview ? Microphone(name: "iPhone Microphone") : DictationChannel.readMicrophone(from: Settings.shared.defaults)
    guard now != shownMicrophone else { return }
    shownMicrophone = now
    guard let now else { mic.attributedText = nil; mic.accessibilityLabel = nil; return }
    let text = NSMutableAttributedString()
    if let image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(font: mic.font))?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
      text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
      text.append(NSAttributedString(string: " "))
    }
    text.append(NSAttributedString(string: now.name, attributes: [.font: mic.font!, .foregroundColor: UIColor.secondaryLabel]))
    mic.attributedText = text
    mic.accessibilityLabel = "Microphone: \(now.name)"
    setNeedsLayout()
  }

  /// Bars 3 pt wide, newest on the right, scrolling left as Voice Memos does; flat while transcribing.
  private func drawWave() {
    let top: CGFloat = 40, bottom = (bottomRow.minY > 0 ? bottomRow.minY : bounds.maxY - 56) - 14
    guard bottom > top else { wave.path = nil; return }
    let mid = (top + bottom) / 2, maxH = bottom - top, bar: CGFloat = 3, pitch: CGFloat = 6
    let n = Int((bounds.width - 24) / pitch)
    let recent = state == .listening ? Array(levels.suffix(n)) : []
    let path = UIBezierPath()
    for i in 0..<n {
      let j = i - (n - recent.count)
      let v = j >= 0 ? CGFloat(recent[j]) : 0
      let h = max(bar, v * maxH)
      let x = 12 + CGFloat(i) * pitch
      path.append(UIBezierPath(roundedRect: CGRect(x: x, y: mid - h / 2, width: bar, height: h), cornerRadius: bar / 2))
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wave.frame = bounds
    wave.fillColor = (state == .listening ? UIColor.label : UIColor.tertiaryLabel).resolvedColor(with: traitCollection).cgColor
    wave.path = path.cgPath
    CATransaction.commit()
  }

  /// Speech-like levels for UI-test screenshots: syllables of varied loudness with short pauses.
  static func fakeLevels(_ t: TimeInterval) -> [Float] {
    (0..<96).map { i in
      let x = t * 20 - Double(95 - i)
      let syllable = abs(sin(x * 0.55)) * (0.55 + 0.45 * sin(x * 0.13 + 1))
      let pause = sin(x * 0.07) > 0.85 ? 0.08 : 1
      return Float(max(0.04, min(1, syllable * pause + 0.05 * sin(x * 3.1))))
    }
  }
}
