import UIKit
import V2TKeyboardCore

/// Apple's three-slot suggestion bar, with the v2t mic at its leading edge showing the dictation state.
final class SuggestionBar: UIView {
  static let height: CGFloat = 44
  var onPick: ((String) -> Void)?
  var onMic: (() -> Void)?
  var dictationState: DictationState = .idle { didSet { updateMic() } }

  private let mic = UIButton(type: .system)
  private let slots = (0..<3).map { _ in UIButton(type: .system) }
  private let dividers = (0..<2).map { _ in UIView() }
  private var words: [String] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    mic.accessibilityIdentifier = "v2t.mic"
    mic.addAction(UIAction { [weak self] _ in self?.onMic?() }, for: .touchUpInside)
    addSubview(mic)
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
    updateMic()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let micW: CGFloat = 46
    mic.frame = CGRect(x: 2, y: 0, width: micW, height: bounds.height)
    let w = (bounds.width - micW - 4) / 3
    for (i, s) in slots.enumerated() { s.frame = CGRect(x: micW + 2 + CGFloat(i) * w, y: 0, width: w, height: bounds.height) }
    for (i, d) in dividers.enumerated() { d.frame = CGRect(x: micW + 2 + CGFloat(i + 1) * w, y: 11, width: 1 / UIScreen.main.scale, height: 22) }
  }

  /// Shows up to three suggestions: the word as typed in quotes (when it is not the best guess), then the
  /// best guess in the middle, as Apple's bar does.
  func show(_ suggestions: [Suggestion]) {
    let ordered = suggestions  // the engine puts the word as typed first, then the best guesses
    words = ordered.map(\.word)
    for (i, s) in slots.enumerated() {
      guard i < ordered.count else { s.setTitle(nil, for: .normal); s.isEnabled = false; continue }
      let sug = ordered[i]
      let title = sug.kind == .typed && ordered.count > 1 ? "“\(sug.word)”" : sug.word
      s.setTitle(title, for: .normal)
      s.titleLabel?.font = .systemFont(ofSize: 17, weight: i == 1 ? .semibold : .regular)
      s.isEnabled = true
    }
  }

  private func updateMic() {
    let (symbol, tint): (String, UIColor) = switch dictationState {
    case .idle: ("mic", .label)
    case .needsApp: ("mic.badge.plus", .label)
    case .listening: ("waveform", .systemRed)
    case .transcribing: ("ellipsis", .systemBlue)
    case .unavailable: ("mic.slash", .secondaryLabel)
    }
    mic.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal)
    mic.tintColor = tint
    mic.accessibilityLabel = switch dictationState {
    case .idle: "Dictate"
    case .needsApp: "Dictate (opens v2t once)"
    case .listening: "Stop dictating"
    case .transcribing: "Transcribing"
    case .unavailable: "Dictation needs Full Access"
    }
  }
}
