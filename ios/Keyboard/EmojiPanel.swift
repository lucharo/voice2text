import CoreText
import UIKit
import V2TKeyboardCore

/// v2t's emoji keyboard, drawn over the suggestion bar and the keys. iOS lets no third-party keyboard open
/// Apple's emoji keyboard, so this follows its look: a grid that scrolls sideways through the categories (the
/// recently used first), the category's name above it, and a bar below with ABC, a button per category and
/// delete. A long press on an emoji with skin tones offers them; the tone picked is shown from then on.
///
/// Memory: one reused cell per visible emoji, each a UILabel; no images are kept. The emoji font keeps every
/// emoji it has drawn decoded, so the panel draws with a private copy of it that it renews (`EmojiFont`).
/// The data (about 37 KB of text) is read when the panel opens; the keyboard drops the panel when it closes.
final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  static let headerHeight: CGFloat = 28
  static let barHeight: CGFloat = 44

  var onEmoji: ((String) -> Void)?
  var onDelete: (() -> Void)?
  var onLetters: (() -> Void)?
  /// iPad only, as Apple's iPad emoji keyboard: hides the keyboard.
  var onDismiss: (() -> Void)? { didSet { dismiss.isHidden = onDismiss == nil; setNeedsLayout() } }
  /// Where iOS draws no globe below the keyboard, the panel covers the keyboard's only globe, so it has one too,
  /// after ABC (Apple's emoji keyboard does the same).
  var onNextKeyboard: (() -> Void)? { didSet { globe.isHidden = onNextKeyboard == nil; setNeedsLayout() } }
  var language: KeyboardLanguage = .english { didSet { updateHeader(force: true) } }

  private let categories: [EmojiCategory]
  private var history: EmojiHistory
  /// The recents as they were when the panel opened: picking an emoji does not reorder the grid under the
  /// finger, as on Apple's keyboard.
  private var recents: [String] = []
  /// Every emoji by its family (`Emoji.family`), so a recent can offer its skin tones too.
  private lazy var families: [String: Emoji] = {
    var out: [String: Emoji] = [:]
    for c in categories { for e in c.emoji { out[Emoji.family(e.base)] = e } }
    return out
  }()

  private let header = UILabel()
  private let flow = UICollectionViewFlowLayout()
  private let grid: UICollectionView
  private let letters = UIButton(type: .system)
  private let delete = DeleteButton(type: .system)
  private let dismiss = UIButton(type: .system)
  private let globe = UIButton(type: .system)
  private var categoryButtons: [UIButton] = []
  private let picker = TonePicker()
  private var deleteTimer: Timer?
  private var emojiSize: CGFloat = 30
  private let emojiFont = EmojiFont()
  private var renewing = false
  private var current = -1
  /// The emoji under a long press: its skin tones are on offer, or (with none) it is typed on release.
  private var pressed: (item: Emoji?, text: String)?
  /// Where the long press began, and whether the finger has since slid far enough to choose another tone:
  /// until then the tone the picker opened on stays chosen, so a tremor does not pick one.
  private var pressStartX: CGFloat = 0
  private var slid = false

  /// Section 0 is the recents; the others follow `categories`.
  private var sectionIDs: [String] { ["recents"] + categories.map(\.id) }

  init(categories: [EmojiCategory], history: EmojiHistory) {
    self.categories = categories
    self.history = history
    flow.scrollDirection = .horizontal
    flow.minimumLineSpacing = 0
    flow.minimumInteritemSpacing = 0
    grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
    super.init(frame: .zero)
    backgroundColor = .clear  // the keyboard's glass, as behind the keys (the controller hides the keys)
    accessibilityIdentifier = "v2t.emoji"

    header.font = .systemFont(ofSize: 12, weight: .semibold)
    header.textColor = .secondaryLabel
    header.accessibilityIdentifier = "emoji.header"
    addSubview(header)

    grid.backgroundColor = .clear
    grid.showsHorizontalScrollIndicator = false
    grid.dataSource = self
    grid.delegate = self
    grid.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuse)
    grid.delaysContentTouches = false
    grid.isPrefetchingEnabled = false  // only the emoji on screen get drawn, and decoded
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
    hold.minimumPressDuration = 0.4
    grid.addGestureRecognizer(hold)
    addSubview(grid)

    letters.setTitle("ABC", for: .normal)
    letters.titleLabel?.font = .systemFont(ofSize: 16)
    letters.tintColor = .label
    letters.accessibilityIdentifier = "emoji.abc"
    letters.accessibilityLabel = "letters"
    letters.addAction(UIAction { [weak self] _ in self?.onLetters?() }, for: .touchUpInside)
    addSubview(letters)

    globe.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
    globe.tintColor = .label
    globe.accessibilityIdentifier = "emoji.globe"
    globe.accessibilityLabel = "next keyboard"
    globe.isHidden = true
    globe.addAction(UIAction { [weak self] _ in self?.onNextKeyboard?() }, for: .touchUpInside)
    addSubview(globe)

    for (i, id) in sectionIDs.enumerated() {
      let b = UIButton(type: .system)
      b.setImage(UIImage(systemName: Self.symbol(id), withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
      b.layer.cornerRadius = 15
      b.accessibilityIdentifier = "emoji.category.\(id)"
      b.addAction(UIAction { [weak self] _ in self?.scroll(to: i) }, for: .touchUpInside)
      addSubview(b)
      categoryButtons.append(b)
    }

    delete.setImage(UIImage(systemName: "delete.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)), for: .normal)
    delete.tintColor = .label
    delete.accessibilityIdentifier = "emoji.delete"
    delete.accessibilityLabel = "delete"
    // as the keys' delete: once on touch-down, then repeating while held
    delete.addAction(UIAction { [weak self] _ in self?.startDelete() }, for: .touchDown)
    delete.onAccessibilityActivate = { [weak self] in self?.onDelete?() }  // VoiceOver sends no touch-down
    for e: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
      delete.addAction(UIAction { [weak self] _ in self?.stopDelete() }, for: e)
    }
    addSubview(delete)

    dismiss.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
    dismiss.tintColor = .label
    dismiss.accessibilityIdentifier = "emoji.dismiss"
    dismiss.accessibilityLabel = "hide keyboard"
    dismiss.isHidden = true
    dismiss.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
    addSubview(dismiss)

    picker.isHidden = true
    addSubview(picker)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// Opens at the recently used emoji (the first category while there are none), with the recents as of now.
  func show() {
    recents = history.recents
    grid.reloadData()
    grid.layoutIfNeeded()
    grid.contentOffset = .zero
    updateHeader(force: true)
  }

  // MARK: layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width, h = bounds.height
    header.frame = CGRect(x: 14, y: 6, width: w - 28, height: Self.headerHeight - 6)
    let gridFrame = CGRect(x: 0, y: Self.headerHeight, width: w, height: max(0, h - Self.headerHeight - Self.barHeight))
    if grid.frame != gridFrame {
      grid.frame = gridFrame
      sizeCells()
      grid.layoutIfNeeded()
      updateHeader(force: true)  // a panel shown before its first layout named the wrong section
    }
    let barY = h - Self.barHeight, side: CGFloat = 52
    letters.frame = CGRect(x: 4, y: barY, width: side, height: Self.barHeight)
    delete.frame = CGRect(x: w - 4 - side, y: barY, width: side, height: Self.barHeight)
    dismiss.frame = CGRect(x: delete.frame.minX - side, y: barY, width: side, height: Self.barHeight)
    globe.frame = CGRect(x: letters.frame.maxX, y: barY, width: 44, height: Self.barHeight)
    let left = globe.isHidden ? letters.frame.maxX : globe.frame.maxX, right = dismiss.isHidden ? delete.frame.minX : dismiss.frame.minX
    let step = (right - left) / CGFloat(categoryButtons.count)
    for (i, b) in categoryButtons.enumerated() {
      let d = min(30, step - 2)
      b.frame = CGRect(x: left + CGFloat(i) * step + (step - d) / 2, y: barY + (Self.barHeight - d) / 2, width: d, height: d)
    }
  }

  /// Five rows on an iPhone, as Apple's; more on the taller iPad keyboard.
  private func sizeCells() {
    let gh = grid.bounds.height
    guard gh > 0 else { return }
    let isPad = bounds.width >= 600  // an iPad's floating keyboard is phone sized, and gets the phone's grid
    let rows = max(3, Int(gh / (isPad ? 56 : 37)))
    let side = floor(gh / CGFloat(rows))
    flow.itemSize = CGSize(width: side + (isPad ? 10 : 5), height: side)
    emojiSize = round(side * 0.76)
    emojiFont.limit = EmojiFont.limit(viewport: grid.bounds.size, cell: flow.itemSize)
    flow.invalidateLayout()
    grid.reloadData()
  }

  // MARK: data

  private func text(at ip: IndexPath) -> String {
    ip.section == 0 ? recents[ip.item] : history.shown(categories[ip.section - 1].emoji[ip.item])
  }

  private func item(at ip: IndexPath) -> Emoji? {
    ip.section == 0 ? families[Emoji.family(recents[ip.item])] : categories[ip.section - 1].emoji[ip.item]
  }

  func numberOfSections(in collectionView: UICollectionView) -> Int { categories.count + 1 }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    section == 0 ? recents.count : categories[section - 1].emoji.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuse, for: ip) as! EmojiCell
    let e = text(at: ip)
    cell.show(e, font: emojiFont.font(size: emojiSize))
    if emojiFont.note(e) { renewSoon() }
    return cell
  }

  /// After the cells on screen are drawn, swaps the font for a fresh one and redraws them with it. An open
  /// skin-tone picker keeps the old copy until it closes.
  private func renewSoon() {
    guard !renewing else { return }
    renewing = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      emojiFont.renew()
      grid.reloadData()
      renewing = false
    }
  }

  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
    self.collectionView(collectionView, numberOfItemsInSection: section) == 0 ? .zero : UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt ip: IndexPath) {
    collectionView.deselectItem(at: ip, animated: false)
    insert(text(at: ip), from: item(at: ip))
  }

  private func insert(_ emoji: String, from item: Emoji?) {
    history.use(emoji, from: item)
    EmojiStore.save(history)
    onEmoji?(emoji)
  }

  // MARK: categories

  /// The section at the left edge of the grid, as Apple's header names it.
  private func visibleSection() -> Int {
    let x = grid.contentOffset.x + 8
    var best = 1
    for s in 0..<numberOfSections(in: grid) where collectionView(grid, numberOfItemsInSection: s) > 0 {
      guard let a = flow.layoutAttributesForItem(at: IndexPath(item: 0, section: s)) else { continue }
      if a.frame.minX - 6 <= x { best = s }
    }
    return best
  }

  private func scroll(to section: Int) {
    if collectionView(grid, numberOfItemsInSection: section) == 0 {
      grid.contentOffset = .zero  // no recents yet: the first category starts there
    } else if let a = flow.layoutAttributesForItem(at: IndexPath(item: 0, section: section)) {
      let maxX = max(0, grid.contentSize.width - grid.bounds.width)
      grid.contentOffset = CGPoint(x: min(maxX, max(0, a.frame.minX - 6)), y: 0)
    }
    current = section  // the button tapped is the one lit, even for the last categories, which cannot scroll to the left edge
    updateHeader(force: true, section: section)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    picker.hide()
    updateHeader(force: false)
  }

  private func updateHeader(force: Bool, section: Int? = nil) {
    let s = section ?? visibleSection()
    guard force || s != current else { return }
    current = s
    header.text = Self.name(sectionIDs[s], language).uppercased()
    for (i, b) in categoryButtons.enumerated() {
      let on = i == s
      b.tintColor = on ? .label : .secondaryLabel
      b.backgroundColor = on ? UIColor.label.withAlphaComponent(0.1) : nil
      b.accessibilityLabel = Self.name(sectionIDs[i], language)
      b.accessibilityTraits = on ? [.button, .selected] : .button
    }
  }

  static func symbol(_ id: String) -> String {
    switch id {
    case "recents": "clock"
    case "smileys": "face.smiling"
    case "animals": "pawprint"
    case "food": "fork.knife"
    case "activity": "soccerball"
    case "travel": "car"
    case "objects": "lightbulb"
    case "symbols": "heart"
    case "flags": "flag"
    default: "questionmark"
    }
  }

  /// Apple's names for its emoji categories.
  static func name(_ id: String, _ lang: KeyboardLanguage) -> String {
    let es = lang == .spanish
    switch id {
    case "recents": return es ? "Usados con frecuencia" : "Frequently Used"
    case "smileys": return es ? "Emoticonos y personas" : "Smileys & People"
    case "animals": return es ? "Animales y naturaleza" : "Animals & Nature"
    case "food": return es ? "Comida y bebida" : "Food & Drink"
    case "activity": return es ? "Actividad" : "Activity"
    case "travel": return es ? "Viajes y lugares" : "Travel & Places"
    case "objects": return es ? "Objetos" : "Objects"
    case "symbols": return es ? "Símbolos" : "Symbols"
    case "flags": return es ? "Banderas" : "Flags"
    default: return id
    }
  }

  // MARK: delete

  private func startDelete() {
    onDelete?()
    deleteTimer?.invalidate()
    deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.onDelete?() }
        }
      }
    }
  }

  private func stopDelete() {
    deleteTimer?.invalidate()
    deleteTimer = nil
  }

  // MARK: skin tones

  @objc private func longPress(_ g: UILongPressGestureRecognizer) {
    switch g.state {
    case .began:
      guard let ip = grid.indexPathForItem(at: g.location(in: grid)), let cell = grid.cellForItem(at: ip) else { return }
      let shown = text(at: ip), it = item(at: ip)
      pressed = (it, shown)
      pressStartX = g.location(in: self).x
      slid = false
      guard let it, !it.skinTones.isEmpty else { return }
      let options = [it.base] + it.skinTones
      let font = emojiFont.font(size: emojiSize)
      var renew = false
      for o in options where emojiFont.note(o) { renew = true }
      picker.show(options, chosen: options.firstIndex(of: shown) ?? 0, over: cell.convert(cell.bounds, to: self), in: bounds,
                  font: font, traits: traitCollection)
      if renew { renewSoon() }
      bringSubviewToFront(picker)
    case .changed:
      guard !picker.isHidden else { return }
      if !slid, abs(g.location(in: self).x - pressStartX) < 10 { return }
      slid = true
      picker.choose(at: g.location(in: picker).x)
    case .ended:
      defer { pressed = nil; picker.hide() }
      guard let p = pressed else { return }
      if picker.isHidden { insert(p.text, from: p.item); return }  // an emoji with no skin tones: typed on release
      let chosen = picker.chosen
      insert(chosen, from: p.item)
      // the category's cell now shows the tone picked; the recents wait until the panel opens again
      let base = p.item?.base
      grid.reloadItems(at: grid.indexPathsForVisibleItems.filter { $0.section > 0 && item(at: $0)?.base == base })
    default:
      pressed = nil
      picker.hide()
    }
  }
}

/// One emoji in the grid.
final class EmojiCell: UICollectionViewCell {
  static let reuse = "emoji"
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    label.textAlignment = .center
    contentView.addSubview(label)
    contentView.layer.cornerRadius = 8
    isAccessibilityElement = true
    accessibilityTraits = .keyboardKey
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = contentView.bounds
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    label.text = nil
    label.font = .systemFont(ofSize: 17)  // a cell waiting for reuse must not keep an old emoji font alive
  }

  override var isHighlighted: Bool {
    didSet { contentView.backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.12) : nil }
  }

  func show(_ emoji: String, font: UIFont) {
    label.font = font
    label.text = emoji
    accessibilityLabel = emoji  // VoiceOver reads an emoji by its name
    accessibilityIdentifier = "emoji.\(emoji)"
  }
}

/// The font the grid draws emoji with. Apple's emoji font keeps the decoded 160 px bitmap of every emoji it
/// has drawn for as long as the font lives, and the system's copy lives as long as the keyboard: in the
/// Simulator each distinct emoji cost about 45 KB, so scrolling through all 1,906 grew the keyboard from 60 MB
/// to 166 MB. A private copy, made from the same font file, gives that memory back when it is released (98 MB
/// back to 41 MB in the same measurement), so the grid swaps in a fresh copy after `limit` distinct emoji.
/// Falls back to the system font if the file cannot be read.
final class EmojiFont {
  /// Distinct emoji drawn before the swap: at least 120 (about 5 MB decoded, two iPhone screens), and always
  /// more than two screens of the grid, so the redraw after a swap can never trigger the next swap.
  var limit = 120

  static func limit(viewport: CGSize, cell: CGSize) -> Int {
    guard cell.width > 0, cell.height > 0 else { return 120 }
    let rows = Int(viewport.height / cell.height), columns = Int((viewport.width / cell.width).rounded(.up)) + 1
    return max(120, 2 * rows * columns + 6)  // + 6: an open skin-tone picker
  }
  private var graphicsFont: CGFont?
  private var sized: [CGFloat: UIFont] = [:]
  private var drawn = Set<String>()

  init() { renew() }

  func font(size: CGFloat) -> UIFont {
    if let f = sized[size] { return f }
    let f: UIFont = graphicsFont.map { CTFontCreateWithGraphicsFont($0, size, nil, nil) as UIFont } ?? .systemFont(ofSize: size)
    sized[size] = f
    return f
  }

  /// Notes that `emoji` was drawn; true once more than `limit` distinct emoji have been drawn with this copy.
  func note(_ emoji: String) -> Bool {
    guard graphicsFont != nil else { return false }
    drawn.insert(emoji)
    return drawn.count > limit
  }

  /// Drops this copy (and every emoji decoded in it) for a fresh one.
  func renew() {
    sized = [:]
    drawn = []
    let system = CTFontCreateWithName("AppleColorEmoji" as CFString, 17, nil)
    guard let url = CTFontCopyAttribute(system, kCTFontURLAttribute) as? URL,
          let provider = CGDataProvider(url: url as CFURL) else { graphicsFont = nil; return }
    graphicsFont = CGFont(provider)
  }
}

/// The panel's delete: VoiceOver activates a button without a touch-down, so it deletes through this.
final class DeleteButton: UIButton {
  var onAccessibilityActivate: (() -> Void)?
  override func accessibilityActivate() -> Bool {
    onAccessibilityActivate?()
    return true
  }
}

/// The row of skin tones over a long-pressed emoji; the finger slides along it to choose.
final class TonePicker: UIView {
  private var labels: [UILabel] = []
  private var options: [String] = []
  private(set) var index = 0
  var chosen: String { options[index] }

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 12
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.25
    layer.shadowRadius = 4
    layer.shadowOffset = CGSize(width: 0, height: 1)
    accessibilityIdentifier = "emoji.tones"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func show(_ options: [String], chosen: Int, over cell: CGRect, in bounds: CGRect, font: UIFont, traits: UITraitCollection) {
    labels.forEach { $0.removeFromSuperview() }
    self.options = options
    // as wide as a cell each, but never wider than the keyboard
    let cellW = min(max(cell.width, font.pointSize + 12), (bounds.width - 12) / CGFloat(options.count)), h = cell.height + 8
    let w = cellW * CGFloat(options.count) + 8
    let x = max(bounds.minX + 2, min(bounds.maxX - w - 2, cell.midX - w / 2))
    // above the emoji when it fits, else below it (the top row)
    let y = cell.minY - h - 4 >= bounds.minY ? cell.minY - h - 4 : cell.maxY + 4
    frame = CGRect(x: x, y: y, width: w, height: h)
    backgroundColor = Palette.key.resolvedColor(with: traits)
    labels = options.enumerated().map { i, e in
      let l = UILabel(frame: CGRect(x: 4 + CGFloat(i) * cellW, y: 4, width: cellW, height: h - 8))
      l.text = e
      l.font = font
      l.textAlignment = .center
      l.layer.cornerRadius = 8
      l.clipsToBounds = true
      l.accessibilityIdentifier = "emoji.tone.\(i)"
      addSubview(l)
      return l
    }
    select(chosen)
    isHidden = false
  }

  /// Hides the picker and lets go of its labels, and so of the emoji font they were drawn with.
  func hide() {
    isHidden = true
    labels.forEach { $0.removeFromSuperview() }
    labels = []
  }

  /// `x` in the picker's own space.
  func choose(at x: CGFloat) {
    guard !labels.isEmpty else { return }
    let w = (bounds.width - 8) / CGFloat(labels.count)
    select(max(0, min(labels.count - 1, Int((x - 4) / w))))
  }

  private func select(_ i: Int) {
    index = i
    for (j, l) in labels.enumerated() { l.backgroundColor = j == i ? UIColor.systemBlue.withAlphaComponent(0.35) : nil }
  }
}

/// The emoji data, read from the keyboard's bundle, and the user's history, kept in the keyboard's own
/// defaults (no Full Access needed).
enum EmojiStore {
  static let recentsKey = "emoji.recents", tonesKey = "emoji.tones"

  static func categories() -> [EmojiCategory] {
    guard let url = Bundle.main.url(forResource: "emoji", withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return EmojiData.parse(text)
  }

  static func load() -> EmojiHistory {
    let d = UserDefaults.standard
    return EmojiHistory(recents: d.stringArray(forKey: recentsKey) ?? [], tones: d.dictionary(forKey: tonesKey) as? [String: String] ?? [:])
  }

  static func save(_ h: EmojiHistory) {
    UserDefaults.standard.set(h.recents, forKey: recentsKey)
    UserDefaults.standard.set(h.tones, forKey: tonesKey)
  }
}
