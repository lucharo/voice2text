import OSLog
import UIKit
import V2TKeyboardCore

let latencyLog = Logger(subsystem: "es.luischav.v2t.keyboard", category: "latency")

/// The v2t keyboard: Apple-style typing (tap, swipe, autocorrect, suggestions) plus a mic key that hands
/// recording to the v2t app, which transcribes on the device and sends the text back.
final class KeyboardViewController: UIInputViewController, KeyboardViewDelegate {
  private var language: KeyboardLanguage = .english
  private var engine: TypingEngine!
  private var decoders: [SwipeDecoder] = []
  private var keyboardView: KeyboardView!
  private let bar = SuggestionBar()
  private let panel = RecordingPanel()
  /// The user cancelled the current dictation: it shows no panel while it is still listening or transcribing;
  /// cleared once the app is idle again.
  private var cancelled = false
  private var heightConstraint: NSLayoutConstraint?
  private var keysHeightConstraint: NSLayoutConstraint?
  private let haptics = UIImpactFeedbackGenerator(style: .light)
  private let decodeQueue = DispatchQueue(label: "v2t.swipe", qos: .userInteractive)
  /// Bumped by every edit, cursor move or host change: a swipe still decoding when it moves is dropped, so its
  /// word never lands in another place or after a later key.
  private var inputEpoch = 0
  /// True while the engine edits the document, so our own edits don't trigger a resync.
  private var engineEditing = false
  private lazy var dictation = DictationClient(controller: self)
  /// Made when the emoji key is tapped, dropped when the panel closes.
  private var emojiPanel: EmojiPanel?
  /// Contact names and no-shortcut phrases from the system's supplementary lexicon.
  private var systemWords = Set<String>()
  /// Open while the user searches emoji: the keys type into it instead of the document.
  private var emojiSearch: EmojiSearchBar? { didSet { searchShift = false } }
  /// Emoji search's own one-tap shift.
  private var searchShift = false
  /// The emoji keywords by language, memory-mapped: the bar's emoji and emoji search.
  private let emojiIndexes: [String: EmojiIndex] = Dictionary(uniqueKeysWithValues: KeyboardLanguage.allCases.compactMap { l in
    Bundle.main.url(forResource: "emoji-keywords-\(l.rawValue)", withExtension: "txt").flatMap { try? EmojiIndex(contentsOf: $0) }.map { (l.rawValue, $0) }
  })
  /// The emoji with skin tones (EmojiData.toned), read from the panel's data the first time the bar or emoji
  /// search offers an emoji, so they come in the tone the user picked.
  private lazy var tonedEmoji: [String: Emoji] = EmojiData.toned(EmojiStore.categories())
  private var barHeightConstraint: NSLayoutConstraint?
  /// The suggestion bar's height, taller while emoji search uses its place.
  private var barHeight: CGFloat { emojiSearch == nil ? SuggestionBar.height : EmojiSearchBar.height }

  override func viewDidLoad() {
    super.viewDidLoad()
    language = Settings.shared.layoutLanguage
    let lexicons = Settings.shared.suggestionLanguages.compactMap { LexiconStore.load($0) }
    let layout = makeLayout(width: max(320, view.bounds.width), page: .letters)
    let proxy = ProxyAdapter(self)
    engine = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: lexicons, layout: layout))
    engine.learned = userWords()
    engine.onLearn = { Settings.shared.learn($0) }
    // a word you keep that no word list knows ("marimo") becomes a v2t dictionary term, for dictation too
    engine.onNewWord = { try? PersonalDictionary().addTerm($0) }
    engine.emojiIndexes = emojiIndexes
    engine.emojiShown = { [weak self] e in self.flatMap { EmojiStore.shown([e], toned: $0.tonedEmoji).first } ?? e }
    decoders = lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) }

    // no background of our own: the system's keyboard glass shows through around and behind the keys, as it
    // does behind Apple's keyboard (an opaque fill sat inside the glass as a lighter or darker box, #111)
    view.backgroundColor = .clear
    // iOS disables its own dictation key (the mic below the keyboard on Face ID iPhones): v2t's mic key dictates
    hasDictationKey = true
    keyboardView = KeyboardView(layout: layout)
    keyboardView.delegate = self
    keyboardView.clipsToBounds = false
    bar.onPick = { [weak self] word in
      guard let self else { return }
      let emoji = engine.emojiSuggestion == word
      edit { $0.pick(word) }
      if emoji { EmojiStore.record(word, toned: tonedEmoji) }  // the bar's emoji joins the panel's recents
    }
    bar.onDismiss = { [weak self] in self?.dismissKeyboard() }
    bar.showsDismiss = !layout.form.isPad
    panel.onStop = { [weak self] in self?.dictation.toggle() }
    panel.onCancel = { [weak self] in
      guard let self else { return }
      cancelled = true  // the keys come straight back; its transcription is not typed
      dictation.cancel()
      showDictation(.listening)  // hides the panel: the cancelled recording shows nothing more
    }
    // the app may end without another notification (quit or crashed): the panel checks the heartbeat itself
    panel.liveState = { [weak self] in self?.dictation.state }
    panel.onStateChange = { [weak self] state in self?.showDictation(state) }
    panel.isHidden = true
    for v in [bar, keyboardView!, panel] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }
    view.bringSubviewToFront(keyboardView)
    view.bringSubviewToFront(panel)  // the recording view covers the keys (key previews draw outside them)
    let h = view.heightAnchor.constraint(equalToConstant: SuggestionBar.height + layout.height)
    h.priority = .defaultHigh
    heightConstraint = h
    barHeightConstraint = bar.heightAnchor.constraint(equalToConstant: SuggestionBar.height)
    let kh = keyboardView.heightAnchor.constraint(equalToConstant: layout.height)
    keysHeightConstraint = kh
    NSLayoutConstraint.activate([
      h, kh,
      bar.topAnchor.constraint(equalTo: view.topAnchor),
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      barHeightConstraint!,
      keyboardView.topAnchor.constraint(equalTo: bar.bottomAnchor),
      keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      panel.topAnchor.constraint(equalTo: view.topAnchor),
      panel.bottomAnchor.constraint(equalTo: keyboardView.bottomAnchor),
      panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    dictation.onText = { [weak self] text in self?.edit { $0.insertFinished(text) } }
    dictation.onState = { [weak self] state in self?.showDictation(state) }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadSettings()
    applyTraits()
    engine.resync()
    refresh()
    emojiPanel?.reload()  // the default skin tone may have changed in the app meanwhile
    dictation.attach()
    if let p = Settings.shared.previewRecording {
      panel.preview = true
      showDictation(DictationState(rawValue: p).flatMap { $0 == .listening ? nil : $0 } ?? .listening)
    }
    // tells the app's setup list the keyboard is on with Full Access; without it the keyboard cannot write here
    if hasFullAccess { Settings.shared.keyboardFullAccessSeen = Date() }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    dictation.detach()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let current = keyboardView.layout, wanted = makeLayout(width: view.bounds.width, page: current.page)
    if view.bounds.width > 0, abs(current.width - view.bounds.width) > 0.5 || current.form != wanted.form || current.metrics != wanted.metrics
      || current.nextKeyboardKey != wanted.nextKeyboardKey {
      relayout(page: current.page)
    }
  }

  /// The full keyboard on a 13-inch iPad, the iPad keyboard on other iPads (not their phone-sized floating
  /// keyboard), taller in landscape; the iPhone keyboard everywhere else.
  private func makeLayout(width: CGFloat, page: KeyboardPage) -> KeyboardLayout {
    var landscape = width > 1100, shortSide = width
    if let screen = view.window?.windowScene?.screen {
      landscape = screen.bounds.width > screen.bounds.height
      shortSide = min(screen.bounds.width, screen.bounds.height)
    }
    let form = KeyboardForm.choose(isPad: traitCollection.userInterfaceIdiom == .pad, width: width, screenShortSide: shortSide)
    // iOS draws its own globe below the keyboard on Face ID iPhones; the emoji key then takes our globe's slot
    return KeyboardLayout(width: width, page: page, language: language, form: form, landscape: form.isPad && landscape,
                          currency: Locale.current.currencySymbol, nextKeyboardKey: Settings.shared.previewGlobeKey ?? needsInputModeSwitchKey)
  }

  /// Words autocorrect never changes: the ones the user kept, v2t's dictionary and the system's (contact
  /// names, phrases in Text Replacement with no shortcut).
  private func userWords() -> Set<String> {
    Settings.shared.learnedWords.union(PersonalDictionary().autocorrectExclusions).union(systemWords)
  }

  /// The app may have changed the layout language, the suggestion languages or the learned words.
  /// The user's text replacements and contact names, as Apple's keyboard uses them (UILexicon). Asked for
  /// each time the keyboard appears, so a replacement changed in Settings meanwhile applies.
  private func loadSystemLexicon() {
    // iOS calls this on its XPC reply queue, not the main thread: a main-actor closure here crashes the keyboard
    // the moment it opens (Swift's isolation check), so everything happens in a hop to main
    requestSupplementaryLexicon { @Sendable [weak self] lexicon in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          let entries = lexicon.entries.map { (input: $0.userInput, text: $0.documentText) }
          let (replacements, words) = TypingEngine.systemLexicon(entries)
          self.engine.replacements = replacements
          self.systemWords = words
          self.engine.learned = self.userWords()
          self.refresh()
        }
      }
    }
  }

  private func reloadSettings() {
    loadSystemLexicon()
    let settings = Settings.shared
    engine.learned = userWords()
    let wanted = settings.suggestionLanguages.map(\.rawValue)
    if settings.layoutLanguage != language || engine.suggester.lexicons.map(\.language) != wanted {
      language = settings.layoutLanguage
      let lexicons = settings.suggestionLanguages.compactMap { LexiconStore.load($0) }
      engine.replaceLayout(with: Suggester(lexicons: lexicons, layout: keyboardView.layout))
      relayout(page: .letters)
    }
  }

  private func relayout(page: KeyboardPage) {
    let layout = makeLayout(width: view.bounds.width, page: page)
    keyboardView.setLayout(layout)
    bar.showsDismiss = !layout.form.isPad
    heightConstraint?.constant = barHeight + layout.height
    keysHeightConstraint?.constant = layout.height
    if !panel.isHidden { showDictation(panel.state) }  // a rotation moves the bottom row the buttons sit on
    syncEmojiPanel()  // the layout language or the keyboard's form may have changed under an open panel
    if page == .letters {
      engine.replaceLayout(with: Suggester(lexicons: engine.suggester.lexicons, layout: layout))
      decoders = engine.suggester.lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) }
    }
    refresh()
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    latencyLog.debug("host textDidChange engineEditing=\(self.engineEditing, privacy: .public)")
    guard !engineEditing else { return }
    inputEpoch += 1
    applyTraits()
    engine.resync()
    refresh()
  }

  override func selectionDidChange(_ textInput: UITextInput?) {
    super.selectionDidChange(textInput)
    latencyLog.debug("host selectionDidChange engineEditing=\(self.engineEditing, privacy: .public)")
    guard !engineEditing else { return }
    inputEpoch += 1
    engine.resync()
    refresh()
  }

  private func applyTraits() {
    let p = textDocumentProxy
    var t = FieldTraits()
    switch p.autocapitalizationType ?? .sentences {
    case .none: t.capitalization = .none
    case .words: t.capitalization = .words
    case .allCharacters: t.capitalization = .all
    default: t.capitalization = .sentences
    }
    let type = p.keyboardType ?? .default
    t.autocorrect = p.autocorrectionType != .no && ![.URL, .emailAddress, .webSearch, .twitter].contains(type)
    if [.URL, .emailAddress].contains(type) { t.capitalization = .none }
    engine.traits = t
    keyboardView.returnLabel = Self.returnLabel(p.returnKeyType ?? .default, language)
    if [.numberPad, .decimalPad, .numbersAndPunctuation, .phonePad, .asciiCapableNumberPad].contains(type), keyboardView.layout.page == .letters {
      relayout(page: .numbers)
    }
  }

  static func returnLabel(_ t: UIReturnKeyType, _ lang: KeyboardLanguage) -> String {
    let es = lang == .spanish
    switch t {
    case .go: return es ? "ir" : "go"
    case .search, .google, .yahoo: return es ? "buscar" : "search"
    case .send: return es ? "enviar" : "send"
    case .next: return es ? "siguiente" : "next"
    case .done: return es ? "OK" : "done"
    case .join: return es ? "unirse" : "join"
    default: return es ? "intro" : "return"
    }
  }

  /// Runs an engine edit without treating the resulting text change as the host's. Logs how long our own
  /// handling took (engine, proxy calls, suggestion refresh): `log stream --predicate 'category == "latency"'`.
  private func edit(_ name: String = "key", _ body: (TypingEngine) -> Void) {
    let t0 = CACurrentMediaTime()
    if name != "swipe-apply" { inputEpoch += 1 }  // a swipe's own word leaves the next queued swipe valid
    engineEditing = true
    body(engine)
    engineEditing = false
    refresh()
    latencyLog.log("\(name, privacy: .public) \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000), privacy: .public) ms")
  }

  private func refresh() {
    // search has its own shift, off unless tapped, and types the shifted mark only (EmojiIndex folds case)
    keyboardView.shift = emojiSearch == nil ? engine.shift : (searchShift ? .on : .off)
    keyboardView.shiftManual = emojiSearch == nil ? engine.shiftManual : true
    bar.show(engine.suggestions(), pending: engine.pendingAutocorrection)
  }

  // MARK: KeyboardViewDelegate

  func keyboardViewKeyDown(_ v: KeyboardView) {
    if hasFullAccess { haptics.impactOccurred(intensity: 0.6) }
    UIDevice.current.playInputClick()
  }

  func keyboardView(_ v: KeyboardView, typed text: String, at point: CGPoint?) {
    if let s = emojiSearch {
      s.type(text)
      if searchShift { searchShift = false; refresh() }
      if v.layout.page != .letters, text == "'" { relayout(page: .letters) }  // as when typing the document
      return
    }
    edit { $0.character(text, at: point, now: CACurrentMediaTime()) }
    // after a sentence-ending mark on the numbers page, go back to letters as Apple does
    if v.layout.page != .letters, text == " " || text == "'" { relayout(page: .letters) }
  }

  func keyboardView(_ v: KeyboardView, action: KeyAction) {
    if let s = emojiSearch {
      switch action {
      case .space:
        s.type(" ")
        if v.layout.page != .letters { relayout(page: .letters) }  // as when typing the document
        return
      case .returnKey, .emoji: endEmojiSearch(); return
      case .shift: searchShift.toggle(); refresh(); return  // its own shift: "!" on the full iPad keyboard
      case .mic, .tab, .capsLock: return  // and the document's shift is left alone
      default: break  // pages, the globe and hide work as usual
      }
    }
    switch action {
    case .space:
      edit { $0.space(now: CACurrentMediaTime()) }
      if v.layout.page != .letters { relayout(page: .letters) }
    case .returnKey: edit { $0.returnKey() }
    case .shift: engine.shiftTap(now: CACurrentMediaTime()); refresh()
    case .capsLock: engine.capsLockTap(); refresh()
    case .tab: edit { $0.character("\t") }
    case .page(let p): relayout(page: p)
    case .mic: startDictation()
    case .emoji: showEmoji(true)
    case .nextKeyboard: advanceToNextInputMode()
    case .dismiss: dismissKeyboard()
    case .character, .delete: break
    }
  }

  func keyboardViewDelete(_ v: KeyboardView, wholeWord: Bool) {
    if let s = emojiSearch { s.deleteBackward(); return }
    edit { wholeWord ? $0.deleteWord() : $0.delete() }
  }

  func keyboardView(_ v: KeyboardView, moveCursor by: Int) {
    guard emojiSearch == nil else { return }  // the space-bar trackpad must not move the document's cursor
    inputEpoch += 1
    engineEditing = true
    textDocumentProxy.adjustTextPosition(byCharacterOffset: by)
    engineEditing = false
    engine.resync()
    refresh()
  }

  func keyboardView(_ v: KeyboardView, swiped trace: [CGPoint]) {
    guard emojiSearch == nil else { return }  // search takes taps only
    var decoder = MultiSwipeDecoder(decoders)
    decoder.languagePrior = engine.suggester.languagePrior  // the language last written in, as the bar's
    let t0 = CACurrentMediaTime()
    let epoch = inputEpoch, document = textDocumentProxy.documentIdentifier
    // the words before the swipe pick the language and promote the words that usually come next
    let context = textDocumentProxy.documentContextBeforeInput ?? ""
    decodeQueue.async {
      defer { latencyLog.log("swipe-decode \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000), privacy: .public) ms") }
      let words = decoder.decode(trace, context: context, limit: 4)
      DispatchQueue.main.async { [weak self] in
        guard let self, !words.isEmpty, self.inputEpoch == epoch, self.emojiSearch == nil,
              self.textDocumentProxy.documentIdentifier == document else { return }
        self.edit("swipe-apply") { $0.swipe(Array(words.prefix(4))) }
      }
    }
  }

  // MARK: emoji

  /// Covers the bar and the keys with the emoji panel, or takes it away (ABC). The panel is dropped when it
  /// closes, with the emoji it has drawn: a keyboard's memory is tight.
  private func showEmoji(_ on: Bool) {
    if on {
      let p = emojiPanel ?? makeEmojiPanel()
      emojiPanel = p
      syncEmojiPanel()
      view.layoutIfNeeded()  // a new panel gets its size before it picks the section to open at
      p.show()
      p.isHidden = !panel.isHidden  // a recording already on screen stays on top until it ends
    } else {
      emojiPanel?.removeFromSuperview()
      emojiPanel = nil
    }
    keyboardView.accessibilityElementsHidden = on
    bar.accessibilityElementsHidden = on
    // the panel is clear like the rest of the keyboard, so the keys and bar it covers are hidden
    keyboardView.isHidden = on || !panel.isHidden
    bar.isHidden = on || !panel.isHidden
    UIAccessibility.post(notification: .screenChanged, argument: on ? emojiPanel : nil)
  }

  /// The panel's category names follow the layout language, the full iPad keyboard's has a hide key, and it
  /// has a globe wherever the keys have one.
  private func syncEmojiPanel() {
    guard let p = emojiPanel else { return }
    if p.language != language { p.language = language }
    let pad = keyboardView.layout.form.isPad
    if pad != (p.onDismiss != nil) { p.onDismiss = pad ? { [weak self] in self?.dismissKeyboard() } : nil }
    let globe = keyboardView.layout.nextKeyboardKey
    if globe != (p.onNextKeyboard != nil) { p.onNextKeyboard = globe ? { [weak self] in self?.advanceToNextInputMode() } : nil }
  }

  private func makeEmojiPanel() -> EmojiPanel {
    let p = EmojiPanel(categories: EmojiStore.categories(), history: EmojiStore.load())
    p.onEmoji = { [weak self] e in self?.edit("emoji") { $0.emoji(e) } }
    p.onDelete = { [weak self] in self?.edit { $0.delete() } }
    p.onSearch = { [weak self] in self?.startEmojiSearch() }
    p.onLetters = { [weak self] in
      guard let self else { return }
      showEmoji(false)
      if keyboardView.layout.page != .letters { relayout(page: .letters) }  // ABC means letters, from any page
    }
    p.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(p, belowSubview: panel)  // dictation's panel still covers everything
    NSLayoutConstraint.activate([
      p.topAnchor.constraint(equalTo: view.topAnchor),
      p.bottomAnchor.constraint(equalTo: keyboardView.bottomAnchor),
      p.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      p.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    return p
  }

  /// Emoji search: the keys come back with the search field and its results in the bar's place.
  private func startEmojiSearch() {
    guard emojiSearch == nil else { return }
    inputEpoch += 1  // a swipe still decoding must not land in the document while search is open
    // the suggestion languages' keywords, the layout language's first
    let langs = [language] + Settings.shared.suggestionLanguages.filter { $0 != language }
    let s = EmojiSearchBar(indexes: langs.compactMap { emojiIndexes[$0.rawValue] }, recents: { EmojiStore.load().recents },
                           tone: { [weak self] list in self.map { EmojiStore.shown(list, toned: $0.tonedEmoji) } ?? list })
    s.onPick = { [weak self] e in
      guard let self else { return }
      edit("emoji") { $0.emoji(e) }
      EmojiStore.record(e, toned: tonedEmoji)
    }
    s.onClose = { [weak self] in self?.endEmojiSearch() }
    s.translatesAutoresizingMaskIntoConstraints = false
    emojiSearch = s
    view.insertSubview(s, belowSubview: keyboardView)  // key previews still draw over it, as over the bar
    NSLayoutConstraint.activate([
      s.topAnchor.constraint(equalTo: bar.topAnchor),
      s.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
      s.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      s.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    emojiPanel?.isHidden = true
    bar.isHidden = true
    keyboardView.isHidden = false  // the keys come back to type the search
    if keyboardView.layout.page != .letters { relayout(page: .letters) }
    resizeBar()
    keyboardView.accessibilityElementsHidden = false
    UIAccessibility.post(notification: .screenChanged, argument: s)
  }

  /// Back to the emoji panel.
  private func endEmojiSearch() {
    guard let s = emojiSearch else { return }
    s.removeFromSuperview()
    emojiSearch = nil
    bar.isHidden = false
    resizeBar()
    showEmoji(true)
  }

  private func resizeBar() {
    barHeightConstraint?.constant = barHeight
    heightConstraint?.constant = barHeight + keyboardView.layout.height
    refresh()
  }

  // MARK: dictation

  private func startDictation() {
    dictation.toggle()
  }

  /// Covers the keys with the recording panel while dictating; the keys come back once the text is in.
  private func showDictation(_ state: DictationState) {
    let active = [.listening, .transcribing, .cleaningUp].contains(state)
    if !active { cancelled = false }
    guard (active && !cancelled) || panel.preview else { setPanel(visible: false); return }
    view.layoutIfNeeded()
    let layout = keyboardView.layout
    let row = layout.keys.filter { $0.row == layout.metrics.rows - 1 }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    panel.show(state, bottomRow: keyboardView.convert(row, to: panel))
    // show() can find the app gone and hide the panel at once (onStateChange): then the keys must come back
    setPanel(visible: !panel.isHidden)
  }

  /// While the panel covers them, the keys and the bar are hidden from VoiceOver and focus moves to Done.
  private func setPanel(visible: Bool) {
    if !visible { panel.hide() }
    let wasModal = panel.accessibilityViewIsModal
    // the emoji panel covers the keys and the bar; emoji search brings the keys back, in place of the bar
    let emoji = emojiPanel != nil && emojiSearch == nil
    keyboardView.accessibilityElementsHidden = visible || emoji
    bar.accessibilityElementsHidden = visible || emojiPanel != nil
    // the panel is clear like the rest of the keyboard, so the keys and bar it replaces are hidden
    keyboardView.isHidden = visible || emoji
    bar.isHidden = visible || emojiPanel != nil
    emojiPanel?.isHidden = visible || emojiSearch != nil  // the clear recording panel would show the emoji grid through it
    emojiSearch?.isHidden = visible
    panel.accessibilityViewIsModal = visible
    if visible != wasModal { UIAccessibility.post(notification: .screenChanged, argument: visible ? panel.focusTarget : nil) }
  }
}

/// UITextDocumentProxy as the engine's TextProxy.
final class ProxyAdapter: TextProxy {
  private weak var controller: UIInputViewController?
  init(_ c: UIInputViewController) { controller = c }
  var documentContextBeforeInput: String? { controller?.textDocumentProxy.documentContextBeforeInput }
  func insertText(_ text: String) { controller?.textDocumentProxy.insertText(text) }
  func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
}

/// Loads the bundled lexicons, memory-mapped.
enum LexiconStore {
  static func load(_ lang: KeyboardLanguage) -> Lexicon? {
    guard let url = Bundle.main.url(forResource: lang.rawValue, withExtension: "v2tlex", subdirectory: "lexicons") else { return nil }
    return try? Lexicon(contentsOf: url, language: lang.rawValue)
  }
}
