import UIKit
import V2TKeyboardCore

/// Emoji search, as on Apple's emoji keyboard: a field above the letter keys and a row of results. The
/// keyboard types into the field instead of the document while it is open (KeyboardViewController routes the
/// keys here); a result goes into the document. With nothing typed, the row shows the recently used emoji.
/// Results come in the skin tone the panel shows each emoji in (the one picked for it, or the default).
final class EmojiSearchBar: UIView {
  /// The suggestion bar's place, made taller for the field and the results.
  static let height: CGFloat = 92

  var onPick: ((String) -> Void)?
  var onClose: (() -> Void)?
  private(set) var query = ""

  private let indexes: [EmojiIndex]
  private let recents: () -> [String]
  /// The results (base forms) in the tones the emoji panel shows them in.
  private let tone: ([String]) -> [String]
  private let back = UIButton(type: .system)
  private let field = UIView()
  private let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
  private let text = UILabel()
  private let caret = UIView()
  private let results = UIScrollView()
  private var buttons: [UIButton] = []
  private let none = UILabel()
  /// Its own copy of the emoji font, let go of with the bar (see EmojiFont).
  private let emojiFont = EmojiFont()

  init(indexes: [EmojiIndex], recents: @escaping () -> [String], tone: @escaping ([String]) -> [String]) {
    self.indexes = indexes
    self.recents = recents
    self.tone = tone
    super.init(frame: .zero)
    backgroundColor = .clear  // the keyboard's glass, as behind the suggestion bar it replaces
    accessibilityIdentifier = "emoji.search"

    back.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
    back.tintColor = .label
    back.accessibilityLabel = "back to emoji"
    back.accessibilityIdentifier = "emoji.search.back"
    back.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
    addSubview(back)

    field.backgroundColor = Palette.key
    field.layer.cornerRadius = 10
    field.isAccessibilityElement = true
    field.accessibilityTraits = .searchField
    field.accessibilityIdentifier = "emoji.search.field"
    addSubview(field)
    glass.tintColor = .secondaryLabel
    glass.contentMode = .scaleAspectFit
    field.addSubview(glass)
    text.font = .systemFont(ofSize: 17)
    text.lineBreakMode = .byTruncatingHead  // a long query shows its end, where the typing is
    field.addSubview(text)
    caret.backgroundColor = .systemBlue
    field.addSubview(caret)

    results.showsHorizontalScrollIndicator = false
    addSubview(results)
    none.font = .systemFont(ofSize: 15)
    none.textColor = .secondaryLabel
    none.textAlignment = .center
    addSubview(none)
    update()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: typing

  func type(_ s: String) {
    query += s
    update()
  }

  func deleteBackward() {
    guard !query.isEmpty else { return }
    query.removeLast()
    update()
  }

  // MARK: drawing

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    back.frame = CGRect(x: 2, y: 6, width: 40, height: 36)
    field.frame = CGRect(x: 44, y: 6, width: w - 52, height: 36)
    glass.frame = CGRect(x: 10, y: 9, width: 18, height: 18)
    let tw = min(text.intrinsicContentSize.width, field.bounds.width - 50)
    text.frame = CGRect(x: 34, y: 0, width: max(tw, field.bounds.width - 44), height: 36)
    caret.frame = CGRect(x: 34 + (query.isEmpty ? 0 : tw) + 1, y: 8, width: 2, height: 20)
    results.frame = CGRect(x: 0, y: 46, width: w, height: bounds.height - 46)
    none.frame = results.frame
    let side = results.bounds.height
    for (i, b) in buttons.enumerated() { b.frame = CGRect(x: 6 + CGFloat(i) * side, y: 0, width: side, height: side) }
    results.contentSize = CGSize(width: 12 + CGFloat(buttons.count) * side, height: side)
  }

  private func update() {
    text.text = query.isEmpty ? "Search Emoji" : query
    text.textColor = query.isEmpty ? .secondaryLabel : .label
    field.accessibilityValue = query
    field.accessibilityLabel = "Search Emoji"
    let found = query.trimmingCharacters(in: .whitespaces).isEmpty ? recents() : tone(EmojiIndex.search(query, in: indexes))
    buttons.forEach { $0.removeFromSuperview() }
    if found.contains(where: { emojiFont.note($0) }) { emojiFont.renew() }  // a fresh copy every so many emoji
    let font = emojiFont.font(size: 30)
    buttons = found.map { e in
      let b = UIButton(type: .custom)
      b.setAttributedTitle(NSAttributedString(string: e, attributes: [.font: font]), for: .normal)
      b.accessibilityLabel = e
      b.accessibilityIdentifier = "emoji.result.\(e)"
      b.addAction(UIAction { [weak self] _ in self?.onPick?(e) }, for: .touchUpInside)
      results.addSubview(b)
      return b
    }
    results.contentOffset = .zero
    none.text = found.isEmpty && !query.isEmpty ? "No Emoji Found" : nil
    setNeedsLayout()
  }
}
