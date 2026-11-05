import UIKit
import V2TKeyboardCore

/// Apple's three-slot suggestion bar. Dictation starts from the mic key on the bottom row; while it records,
/// RecordingPanel covers the bar and the keys.
final class SuggestionBar: UIView {
  static let height: CGFloat = 44
  var onPick: ((String) -> Void)?

  private let slots = (0..<3).map { _ in UIButton(type: .system) }
  private let dividers = (0..<2).map { _ in UIView() }
  private var words: [String] = []

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
    for d in dividers {
      d.backgroundColor = .separator
      addSubview(d)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 4
    let w = (bounds.width - 2 * inset) / 3
    for (i, s) in slots.enumerated() { s.frame = CGRect(x: inset + CGFloat(i) * w, y: 0, width: w, height: bounds.height) }
    for (i, d) in dividers.enumerated() { d.frame = CGRect(x: inset + CGFloat(i + 1) * w, y: 11, width: 1 / UIScreen.main.scale, height: 22) }
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
      s.titleLabel?.font = .systemFont(ofSize: 17, weight: pending != nil && sug.word == pending ? .semibold : .regular)
      s.isEnabled = true
    }
  }
}
