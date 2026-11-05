import UIKit

/// What the keyboard shows while it records and transcribes, in place of the keys: a live waveform of the
/// microphone and a large control to finish. Three styles are prototyped (Settings.recordingStyle):
/// A, a wide Stop button where the space bar is; B, Cancel and Done; C, Stop on the mic key's own spot.
final class RecordingPanel: UIView {
  enum Style: String { case a = "A", b = "B", c = "C" }

  var onStop: (() -> Void)?
  var onCancel: (() -> Void)?

  private let wave = CAShapeLayer()
  private let status = UILabel()
  private let dot = UIView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let stop = UIButton(type: .system)
  private let cancel = UIButton(type: .system)
  private let done = UIButton(type: .system)
  private var timer: Timer?
  private var started = Date()
  private var levels: [Float] = []
  private var style: Style = .a
  private var state: DictationState = .idle
  /// The bottom row of keys and the mic key, in this view's coordinates, so the controls sit where keys were.
  private var bottomRow: CGRect = .zero
  private var micKey: CGRect = .zero
  /// UI tests: a made-up waveform instead of the app's levels file.
  var preview = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Palette.background
    wave.fillColor = UIColor.label.cgColor
    layer.addSublayer(wave)
    status.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    status.textColor = .secondaryLabel
    dot.backgroundColor = .systemRed
    dot.layer.cornerRadius = 4
    spinner.hidesWhenStopped = true
    for v in [status, dot, spinner, stop, cancel, done] as [UIView] { addSubview(v) }

    stop.configuration = Self.filled(title: "Stop", symbol: "stop.fill", color: .systemRed)
    stop.accessibilityIdentifier = "v2t.recording.stop"
    stop.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
    done.configuration = Self.filled(title: "Done", symbol: "checkmark", color: .systemBlue)
    done.accessibilityIdentifier = "v2t.recording.done"
    done.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
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

  private static func filled(title: String?, symbol: String, color: UIColor) -> UIButton.Configuration {
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

  /// Shows the panel for `state`, with its controls laid over the keyboard's `bottomRow` and `micKey`.
  func show(_ state: DictationState, style: Style, bottomRow: CGRect, micKey: CGRect) {
    if isHidden || state != self.state { started = state == .listening ? Date() : started }
    self.state = state
    self.style = style
    self.bottomRow = bottomRow
    self.micKey = micKey
    isHidden = false
    let listening = state == .listening
    stop.isHidden = !listening || style == .b
    cancel.isHidden = !listening || style != .b
    done.isHidden = !listening || style != .b
    stop.configuration?.title = style == .c ? nil : "Stop"
    dot.isHidden = !listening
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
    spinner.center = CGPoint(x: bounds.midX, y: (bottomRow.minY > 0 ? bottomRow.midY : bounds.maxY - 30))
    let row = bottomRow.height > 0 ? bottomRow : CGRect(x: 3, y: bounds.maxY - 50, width: bounds.width - 6, height: 42)
    switch style {
    case .a:
      stop.frame = row.insetBy(dx: side, dy: -3)
    case .b:
      let cw = (row.width - 2 * side) * 0.32
      cancel.frame = CGRect(x: row.minX + side, y: row.minY - 3, width: cw, height: row.height + 6)
      done.frame = CGRect(x: cancel.frame.maxX + 10, y: row.minY - 3, width: row.maxX - side - cancel.frame.maxX - 10, height: row.height + 6)
    case .c:
      let d = max(micKey.height + 14, 56)
      stop.frame = CGRect(x: min(micKey.midX - d / 2, bounds.maxX - d - 4), y: min(micKey.midY - d / 2, bounds.maxY - d - 2), width: d, height: d)
    }
    drawWave()
  }

  private func tick() {
    if state == .listening {
      levels = preview ? Self.fakeLevels(Date().timeIntervalSince(started)) : DictationChannel.readLevels()
      let s = Int(Date().timeIntervalSince(started))
      status.text = String(format: "%d:%02d", s / 60, s % 60)
    } else {
      status.text = "Transcribing…"
    }
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
