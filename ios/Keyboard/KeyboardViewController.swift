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
  private var heightConstraint: NSLayoutConstraint?
  private let haptics = UIImpactFeedbackGenerator(style: .light)
  private let decodeQueue = DispatchQueue(label: "v2t.swipe", qos: .userInteractive)
  /// True while the engine edits the document, so our own edits don't trigger a resync.
  private var engineEditing = false
  private lazy var dictation = DictationClient(controller: self)

  override func viewDidLoad() {
    super.viewDidLoad()
    language = Settings.shared.layoutLanguage
    let lexicons = Settings.shared.suggestionLanguages.compactMap { LexiconStore.load($0) }
    let layout = KeyboardLayout(width: max(320, view.bounds.width), language: language)
    let proxy = ProxyAdapter(self)
    engine = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: lexicons, layout: layout))
    engine.learned = Settings.shared.learnedWords
    engine.onLearn = { Settings.shared.learn($0) }
    decoders = lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) }

    view.backgroundColor = Palette.background
    keyboardView = KeyboardView(layout: layout)
    keyboardView.delegate = self
    keyboardView.clipsToBounds = false
    bar.onPick = { [weak self] word in self?.edit { $0.pick(word) } }
    bar.onMic = { [weak self] in self?.startDictation() }
    for v in [bar, keyboardView!] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }
    view.bringSubviewToFront(keyboardView)
    let h = view.heightAnchor.constraint(equalToConstant: SuggestionBar.height + KeyboardLayout.height)
    h.priority = .defaultHigh
    heightConstraint = h
    NSLayoutConstraint.activate([
      h,
      bar.topAnchor.constraint(equalTo: view.topAnchor),
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: SuggestionBar.height),
      keyboardView.topAnchor.constraint(equalTo: bar.bottomAnchor),
      keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      keyboardView.heightAnchor.constraint(equalToConstant: KeyboardLayout.height),
    ])
    dictation.onText = { [weak self] text in self?.edit { $0.insertFinished(text) } }
    dictation.onState = { [weak self] state in self?.bar.dictationState = state }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadSettings()
    applyTraits()
    engine.resync()
    refresh()
    dictation.attach()
    // tells the app's setup list the keyboard is on with Full Access; without it the keyboard cannot write here
    if hasFullAccess { Settings.shared.keyboardFullAccessSeen = Date() }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    dictation.detach()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if abs(keyboardView.layout.width - view.bounds.width) > 0.5, view.bounds.width > 0 {
      relayout(page: keyboardView.layout.page)
    }
  }

  /// The app may have changed the layout language, the suggestion languages or the learned words.
  private func reloadSettings() {
    let settings = Settings.shared
    engine.learned = settings.learnedWords
    let wanted = settings.suggestionLanguages.map(\.rawValue)
    if settings.layoutLanguage != language || engine.suggester.lexicons.map(\.language) != wanted {
      language = settings.layoutLanguage
      let lexicons = settings.suggestionLanguages.compactMap { LexiconStore.load($0) }
      engine.suggester = Suggester(lexicons: lexicons, layout: keyboardView.layout)
      relayout(page: .letters)
    }
  }

  private func relayout(page: KeyboardPage) {
    let layout = KeyboardLayout(width: view.bounds.width, page: page, language: language)
    keyboardView.setLayout(layout)
    if page == .letters {
      engine.suggester = Suggester(lexicons: engine.suggester.lexicons, layout: layout)
      decoders = engine.suggester.lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) }
    }
    refresh()
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    latencyLog.debug("host textDidChange engineEditing=\(self.engineEditing, privacy: .public)")
    guard !engineEditing else { return }
    applyTraits()
    engine.resync()
    refresh()
  }

  override func selectionDidChange(_ textInput: UITextInput?) {
    super.selectionDidChange(textInput)
    latencyLog.debug("host selectionDidChange engineEditing=\(self.engineEditing, privacy: .public)")
    guard !engineEditing else { return }
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
    engineEditing = true
    body(engine)
    engineEditing = false
    refresh()
    latencyLog.log("\(name, privacy: .public) \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000), privacy: .public) ms")
  }

  private func refresh() {
    keyboardView.shift = engine.shift
    bar.show(engine.suggestions())
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
    case .page(let p): relayout(page: p)
    case .mic: startDictation()
    case .emoji: advanceToNextInputMode()  // until the emoji page lands: hand over to the next keyboard
    case .character, .delete: break
    }
  }

  func keyboardViewDelete(_ v: KeyboardView, wholeWord: Bool) {
    edit { wholeWord ? $0.deleteWord() : $0.delete() }
  }

  func keyboardView(_ v: KeyboardView, moveCursor by: Int) {
    engineEditing = true
    textDocumentProxy.adjustTextPosition(byCharacterOffset: by)
    engineEditing = false
    engine.resync()
    refresh()
  }

  func keyboardView(_ v: KeyboardView, swiped trace: [CGPoint]) {
    let decoders = self.decoders
    let t0 = CACurrentMediaTime()
    decodeQueue.async {
      defer { latencyLog.log("swipe-decode \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000), privacy: .public) ms") }
      let merged = decoders.flatMap { $0.decode(trace, limit: 4) }.sorted { $0.score > $1.score }
      var seen = Set<String>()
      let words = merged.map(\.word).filter { seen.insert($0.lowercased()).inserted }
      DispatchQueue.main.async { [weak self] in
        guard let self, !words.isEmpty else { return }
        self.edit("swipe-apply") { $0.swipe(Array(words.prefix(4))) }
      }
    }
  }

  // MARK: dictation

  private func startDictation() {
    dictation.toggle()
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
