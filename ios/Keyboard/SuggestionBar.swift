import UIKit
import V2TKeyboardCore

/// Apple's three-slot suggestion bar, plus a hide-keyboard chevron at its end on the iPhone (as Gboard's bar
/// has): a keyboard never sees taps outside itself, so it cannot hide when the user taps away. Dictation starts
/// from the mic key on the bottom row; while it records, RecordingPanel covers the bar and the keys.
final class SuggestionBar: UIView {
  static let height: CGFloat = 44
  /// Width of the hide-keyboard button at the bar's trailing end.
  static let dismissWidth: CGFloat = 40
  /// A slot was tapped: its word and its index (0 left, 1 the middle, 2 right).
  var onPick: ((String, Int) -> Void)?
  var onDismiss: (() -> Void)?
  /// Off on the iPad, whose bottom row has its own hide-keyboard key.
  var showsDismiss = true { didSet { dismiss.isHidden = !showsDismiss; dismissDivider.isHidden = !showsDismiss; setNeedsLayout() } }

  private let slots = (0..<3).map { _ in UIButton(type: .system) }
  private let dividers = (0..<2).map { _ in UIView() }
  private let dismiss = UIButton(type: .system)
  private let dismissDivider = UIView()
  /// The keyboard debug log is recording (#162): a small red dot at the bar's leading corner.
  var showsDebugDot = false { didSet { debugDot.isHidden = !showsDebugDot } }
  private let debugDot = UIView()
  private var words: [String] = []
  private let emojiFont = EmojiFont()
  /// A short note over the slots ("Done in 1.4 s"), gone after a moment or at the next key touch.
  private let notice = UILabel()
  private var noticeTimer: Timer?
  private let pendingContainer = UIView()
  private let pendingDismiss = UIButton(type: .system)
  private let pendingInsert = UIButton(type: .system)
  private var onPendingInsert: (() -> Void)?
  private var onPendingDismiss: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    for (i, s) in slots.enumerated() {
      s.titleLabel?.font = .systemFont(ofSize: 17)
      s.titleLabel?.lineBreakMode = .byTruncatingMiddle
      s.setTitleColor(.label, for: .normal)
      s.accessibilityIdentifier = "v2t.suggestion.\(i)"
      s.addAction(UIAction { [weak self] _ in
        guard let self, i < self.words.count else { return }
        self.onPick?(self.words[i], i)
      }, for: .touchUpInside)
      addSubview(s)
    }
    for d in dividers + [dismissDivider] {
      d.backgroundColor = .separator
      addSubview(d)
    }
    let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    dismiss.setImage(chevron, for: .normal)
    dismiss.tintColor = .secondaryLabel
    dismiss.accessibilityIdentifier = "v2t.dismiss"
    dismiss.accessibilityLabel = "Hide keyboard"
    dismiss.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
    addSubview(dismiss)
    debugDot.backgroundColor = .systemRed
    debugDot.layer.cornerRadius = 3
    debugDot.isHidden = true
    debugDot.isUserInteractionEnabled = false  // a tap on it reaches the chevron underneath
    debugDot.isAccessibilityElement = true
    debugDot.accessibilityIdentifier = "v2t.debugLog"
    debugDot.accessibilityLabel = "Keyboard debug log is on"
    addSubview(debugDot)
    notice.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    notice.textColor = .secondaryLabel
    notice.textAlignment = .center
    notice.isHidden = true
    notice.accessibilityIdentifier = "v2t.notice"
    addSubview(notice)

    pendingContainer.isHidden = true
    var dc = UIButton.Configuration.filled()
    dc.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
    dc.baseBackgroundColor = .secondarySystemFill
    dc.baseForegroundColor = .secondaryLabel
    dc.cornerStyle = .capsule
    dc.contentInsets = .zero
    pendingDismiss.configuration = dc
    pendingDismiss.accessibilityIdentifier = "v2t.pending.dismiss"
    pendingDismiss.accessibilityLabel = "Dismiss dictation"
    pendingDismiss.addAction(UIAction { [weak self] _ in self?.onPendingDismiss?() }, for: .touchUpInside)

    var ic = UIButton.Configuration.tinted()
    ic.baseBackgroundColor = .systemBlue
    ic.baseForegroundColor = .systemBlue
    ic.cornerStyle = .capsule
    ic.image = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
    ic.imagePadding = 6
    ic.titleLineBreakMode = .byTruncatingTail
    ic.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
    pendingInsert.configuration = ic
    pendingInsert.accessibilityIdentifier = "v2t.pending.insert"
    pendingInsert.addAction(UIAction { [weak self] _ in self?.onPendingInsert?() }, for: .touchUpInside)

    pendingContainer.addSubview(pendingDismiss)
    pendingContainer.addSubview(pendingInsert)
    addSubview(pendingContainer)
  }

  /// Shows `text` in place of the suggestions for `seconds`, or until `clearNotice()`.
  func showNotice(_ text: String, for seconds: TimeInterval = 2) {
    guard pendingContainer.isHidden else { return }
    notice.text = text
    setNotice(visible: true)
    noticeTimer?.invalidate()
    noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.clearNotice() }
    }
  }

  func clearNotice() {
    noticeTimer?.invalidate()
    noticeTimer = nil
    guard !notice.isHidden else { return }
    UIView.animate(withDuration: 0.2) { self.setNotice(visible: false) } completion: { _ in
      if self.noticeTimer == nil { self.notice.isHidden = true }  // unless a new notice came meanwhile
    }
  }

  /// Shows a tappable banner to insert a transcript that arrived while the user kept typing after Done.
  func showPendingTranscript(_ text: String, onInsert: @escaping () -> Void, onDismiss: @escaping () -> Void) {
    noticeTimer?.invalidate()
    noticeTimer = nil
    notice.isHidden = true
    notice.alpha = 0
    onPendingInsert = onInsert
    onPendingDismiss = onDismiss
    var cfg = pendingInsert.configuration
    var title = AttributedString("Insert: \(text)")
    title.font = .systemFont(ofSize: 14, weight: .medium)
    cfg?.attributedTitle = title
    pendingInsert.configuration = cfg
    pendingInsert.accessibilityLabel = "Insert dictation: \(text)"
    pendingContainer.isHidden = false
    for v in slots as [UIView] + dividers {
      v.alpha = 0
      v.isUserInteractionEnabled = false
    }
    setNeedsLayout()
  }

  func clearPendingTranscript() {
    guard !pendingContainer.isHidden || onPendingInsert != nil else { return }
    pendingContainer.isHidden = true
    onPendingInsert = nil
    onPendingDismiss = nil
    if notice.isHidden {
      for v in slots as [UIView] + dividers {
        v.alpha = 1
        v.isUserInteractionEnabled = true
      }
    }
  }

  private func setNotice(visible: Bool) {
    if visible { notice.isHidden = false }
    notice.alpha = visible ? 1 : 0
    if visible || pendingContainer.isHidden {
      for v in slots as [UIView] + dividers {
        v.alpha = visible ? 0 : 1  // hidden slots take no taps
        v.isUserInteractionEnabled = !visible
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 4, hairline = 1 / UIScreen.main.scale
    let end = showsDismiss ? bounds.width - Self.dismissWidth : bounds.width - inset
    let w = (end - inset) / 3
    for (i, s) in slots.enumerated() { s.frame = CGRect(x: inset + CGFloat(i) * w, y: 0, width: w, height: bounds.height) }
    for (i, d) in dividers.enumerated() { d.frame = CGRect(x: inset + CGFloat(i + 1) * w, y: 11, width: hairline, height: 22) }
    dismissDivider.frame = CGRect(x: end, y: 11, width: hairline, height: 22)
    dismiss.frame = CGRect(x: end, y: 0, width: Self.dismissWidth, height: bounds.height)
    // a badge at the chevron's top right, clear of the keyboard's rounded corners and of the words; without
    // the chevron, at the bar's right edge, centred
    debugDot.frame = showsDismiss
      ? CGRect(x: end + Self.dismissWidth / 2 + 7, y: bounds.midY - 12, width: 6, height: 6)
      : CGRect(x: bounds.width - 12, y: bounds.midY - 3, width: 6, height: 6)
    bringSubviewToFront(debugDot)
    notice.frame = CGRect(x: inset, y: 0, width: end - inset, height: bounds.height)
    let pendingW = max(0, end - inset)
    pendingContainer.frame = CGRect(x: inset, y: 0, width: pendingW, height: bounds.height)
    pendingDismiss.frame = CGRect(x: 4, y: (bounds.height - 30) / 2, width: 30, height: 30)
    let insX = pendingDismiss.frame.maxX + 6
    pendingInsert.frame = CGRect(x: insX, y: (bounds.height - 32) / 2, width: max(0, pendingW - insX - 4), height: 32)
    bringSubviewToFront(pendingContainer)
    bringSubviewToFront(debugDot)
  }

  /// Shows up to three suggestions: the word as typed in quotes (when it is not the best guess), then the
  /// best guess in the middle, as Apple's bar does. `pending` is the word a space would put in, shown bold.
  func show(_ suggestions: [Suggestion], pending: String?) {
    let ordered = suggestions  // the engine puts the word as typed first, then the best guesses
    words = ordered.map(\.word)
    for (i, s) in slots.enumerated() {
      guard i < ordered.count else { s.setTitle(nil, for: .normal); s.isEnabled = false; continue }
      let sug = ordered[i]
      let title = sug.kind == .typed && ordered.count > 1 ? "“\(sug.word)”" : sug.word
      s.setTitle(title, for: .normal)
      if sug.kind == .emoji {
        // a private emoji font, renewed like the panel's, so emoji offered while typing don't pile up decoded
        if emojiFont.note(sug.word) { emojiFont.renew() }
        s.titleLabel?.font = emojiFont.font(size: 24)
      } else {
        s.titleLabel?.font = .systemFont(ofSize: 17, weight: pending != nil && sug.word == pending ? .semibold : .regular)
      }
      s.isEnabled = true
    }
  }
}
