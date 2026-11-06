import UIKit
import V2TKeyboardCore

/// Apple's three-slot suggestion bar, plus a hide-keyboard chevron at its end on the iPhone (as Gboard's bar
/// has): a keyboard never sees taps outside itself, so it cannot hide when the user taps away. Dictation starts
/// from the mic key on the bottom row; while it records, RecordingPanel covers the bar and the keys.
final class SuggestionBar: UIView {
  static let height: CGFloat = 44
  /// Width of the hide-keyboard button at the bar's trailing end.
  static let dismissWidth: CGFloat = 40
  var onPick: ((String) -> Void)?
  var onDismiss: (() -> Void)?
  /// Off on the iPad, whose bottom row has its own hide-keyboard key.
  var showsDismiss = true { didSet { dismiss.isHidden = !showsDismiss; dismissDivider.isHidden = !showsDismiss; setNeedsLayout() } }

  private let slots = (0..<3).map { _ in UIButton(type: .system) }
  private let dividers = (0..<2).map { _ in UIView() }
  private let dismiss = UIButton(type: .system)
  private let dismissDivider = UIView()
  private var words: [String] = []
  private let emojiFont = EmojiFont()

  override init(frame: CGRect) {
    super.init(frame: frame)
    for (i, s) in slots.enumerated() {
      s.titleLabel?.font = .systemFont(ofSize: 17)
      s.titleLabel?.lineBreakMode = .byTruncatingMiddle
      s.setTitleColor(.label, for: .normal)
      s.accessibilityIdentifier = "v2t.suggestion.\(i)"
      s.addAction(UIAction { [weak self] _ in
        guard let self, i < self.words.count else { return }
        self.onPick?(self.words[i])
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
