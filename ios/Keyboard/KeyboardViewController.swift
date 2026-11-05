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

  override func viewDidLoad() {
    super.viewDidLoad()
    language = Settings.shared.layoutLanguage
    let lexicons = Settings.shared.suggestionLanguages.compactMap { LexiconStore.load($0) }
    let layout = makeLayout(width: max(320, view.bounds.width), page: .letters)
    let proxy = ProxyAdapter(self)
    engine = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: lexicons, layout: layout))
    engine.learned = Settings.shared.learnedWords.union(PersonalDictionary().autocorrectExclusions)
    engine.onLearn = { Settings.shared.learn($0) }
    decoders = lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) }

    view.backgroundColor = Palette.background
    keyboardView = KeyboardView(layout: layout)
    keyboardView.delegate = self
    keyboardView.clipsToBounds = false
    bar.onPick = { [weak self] word in self?.edit { $0.pick(word) } }
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
    let kh = keyboardView.heightAnchor.constraint(equalToConstant: layout.height)
    keysHeightConstraint = kh
    NSLayoutConstraint.activate([
      h, kh,
      bar.topAnchor.constraint(equalTo: view.topAnchor),
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: SuggestionBar.height),
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
    dictation.attach()
    if let p = Settings.shared.previewRecording {
      panel.preview = true
      showDictation(p == "transcribing" ? .transcribing : .listening)
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
    if view.bounds.width > 0, abs(current.width - view.bounds.width) > 0.5 || current.form != wanted.form || current.metrics != wanted.metrics {
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
    return KeyboardLayout(width: width, page: page, language: language, form: form, landscape: form.isPad && landscape,
                          currency: Locale.current.currencySymbol)
  }

  /// The app may have changed the layout language, the suggestion languages or the learned words.
  private func reloadSettings() {
    let settings = Settings.shared
    engine.learned = settings.learnedWords.union(PersonalDictionary().autocorrectExclusions)  // the dictionary is never corrected away
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
    heightConstraint?.constant = SuggestionBar.height + layout.height
    keysHeightConstraint?.constant = layout.height
    if !panel.isHidden { showDictation(panel.state) }  // a rotation moves the bottom row the buttons sit on
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
    keyboardView.shift = engine.shift
    keyboardView.shiftManual = engine.shiftManual
    bar.show(engine.suggestions(), pending: engine.pendingAutocorrection)
  }

  // MARK: KeyboardViewDelegate

  func keyboardViewKeyDown(_ v: KeyboardView) {
    if hasFullAccess { haptics.impactOccurred(intensity: 0.6) }
    UIDevice.current.playInputClick()
  }

  func keyboardView(_ v: KeyboardView, typed text: String, at point: CGPoint?) {
    edit { $0.character(text, at: point, now: CACurrentMediaTime()) }
    // after a sentence-ending mark on the numbers page, go back to letters as Apple does
    if v.layout.page != .letters, text == " " || text == "'" { relayout(page: .letters) }
  }

  func keyboardView(_ v: KeyboardView, action: KeyAction) {
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
    case .emoji: advanceToNextInputMode()  // until the emoji page lands: hand over to the next keyboard
    case .dismiss: dismissKeyboard()
    case .character, .delete: break
    }
  }

  func keyboardViewDelete(_ v: KeyboardView, wholeWord: Bool) {
    edit { wholeWord ? $0.deleteWord() : $0.delete() }
  }

  func keyboardView(_ v: KeyboardView, moveCursor by: Int) {
    inputEpoch += 1
    engineEditing = true
    textDocumentProxy.adjustTextPosition(byCharacterOffset: by)
    engineEditing = false
    engine.resync()
    refresh()
  }

  func keyboardView(_ v: KeyboardView, swiped trace: [CGPoint]) {
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
        guard let self, !words.isEmpty, self.inputEpoch == epoch,
              self.textDocumentProxy.documentIdentifier == document else { return }
        self.edit("swipe-apply") { $0.swipe(Array(words.prefix(4))) }
      }
    }
  }

  // MARK: dictation

  private func startDictation() {
    dictation.toggle()
  }

  /// Covers the keys with the recording panel while dictating; the keys come back once the text is in.
  private func showDictation(_ state: DictationState) {
    let active = state == .listening || state == .transcribing
    if !active { cancelled = false }
    guard (active && !cancelled) || panel.preview else { setPanel(visible: false); return }
    view.layoutIfNeeded()
    let layout = keyboardView.layout
    let row = layout.keys.filter { $0.row == layout.metrics.rows - 1 }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    panel.show(state, bottomRow: keyboardView.convert(row, to: panel))
    setPanel(visible: true)
  }

  /// While the panel covers them, the keys and the bar are hidden from VoiceOver and focus moves to Done.
  private func setPanel(visible: Bool) {
    if !visible { panel.hide() }
    let wasModal = panel.accessibilityViewIsModal
    keyboardView.accessibilityElementsHidden = visible
    bar.accessibilityElementsHidden = visible
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
