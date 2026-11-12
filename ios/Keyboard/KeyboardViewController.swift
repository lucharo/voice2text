import OSLog
import UIKit
import V2TKeyboardCore

let latencyLog = Logger(subsystem: "es.luischav.v2t.keyboard", category: "latency")

/// The v2t keyboard: Apple-style typing (tap, swipe, autocorrect, suggestions) plus a mic key that hands
/// recording to the v2t app, which transcribes on the device and sends the text back.
final class KeyboardViewController: UIInputViewController, KeyboardViewDelegate {
  private var language: KeyboardLanguage = .english
  private var engine: TypingEngine!
  private var proxy: ProxyAdapter!
  /// The opt-in debug log (#162), while the app's switch is on.
  private var debugLog: KeyboardDebugLog?
  /// Why the log is paused in this field ("password", "one-time-code", "card"), nil while it records.
  private var debugSkip: String?
  /// The bar as last logged, so only changes are written.
  private var loggedBar: [String] = []
  /// The fields a dictation went into: from then on the log keeps no text read back from them (the text before the
  /// cursor, the bar's words, picked words), since that text holds the dictated words.
  private var dictatedFields = Set<UUID>()
  /// A key was typed since the keyboard opened or the host app changed the text or moved the cursor. Until then
  /// the bar's words come from text the keyboard did not type (a dictation before the keyboard reopened, a paste),
  /// so they are not recorded.
  private var typedSinceHost = false
  /// True while nothing read back from the current field may be logged.
  private var fieldRedacted: Bool {
    !typedSinceHost || engine.holdsReadBackText || documentID.map(dictatedFields.contains) ?? false
  }
  /// The field's identifier, nil while the keyboard closes. Swift declares `documentIdentifier` non-optional, but
  /// iOS hands back nil then, and reading it straight crashes the keyboard (as the debug log UI test found).
  private var documentID: UUID? { (textDocumentProxy as? NSObject)?.value(forKey: "documentIdentifier") as? UUID }
  private var decoders: [SwipeDecoder] = []
  private var keyboardView: KeyboardView!
  private let bar = SuggestionBar()
  private let panel = RecordingPanel()
  /// The user cancelled the current dictation: it shows no panel while it is still listening or transcribing;
  /// cleared once the app is idle again.
  private var cancelled = false
  /// When Done was tapped for the dictation whose wait just ended, if the panel closed before its text came.
  private var waitEndedFrom: Date?
  /// Seconds from Done to the text, held while the panel is still up: the app sends the text before it
  /// reports idle, so "Done in 1.4 s" waits for the keys and the bar to come back.
  private var doneIn: TimeInterval?
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
  /// The suggestion bar's height, taller while emoji search uses its place, and by the search field's row while
  /// the emoji panel covers it.
  private var barHeight: CGFloat {
    if emojiSearch != nil { return EmojiSearchBar.height }
    return emojiPanel == nil ? SuggestionBar.height : SuggestionBar.height + EmojiPanel.searchHeight
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    language = Settings.shared.layoutLanguage
    let lexicons = Settings.shared.suggestionLanguages.compactMap { LexiconStore.load($0) }
    let layout = makeLayout(width: max(320, view.bounds.width), page: .letters)
    proxy = ProxyAdapter(self)
    engine = TypingEngine(proxy: proxy, suggester: Suggester(lexicons: lexicons, layout: layout))
    engine.learned = userWords()
    engine.onLearn = { Settings.shared.learn($0) }
    // a word you keep that no word list knows ("marimo") becomes a v2t dictionary term, for dictation too
    engine.onNewWord = { [weak self] word in
      guard (try? PersonalDictionary().addTerm(word)) != nil else { return }  // already there, or the App Group is closed
      self?.bar.showNotice(Self.addedLabel(word))
    }
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
    bar.onPick = { [weak self] word, slot in
      guard let self else { return }
      let emoji = engine.emojiSuggestion == word
      dlog("pick", [.init("slot", .i(slot))] + (fieldRedacted ? [] : [.init("word", .s(word))]) + [.init("emoji", .b(emoji))])
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
    dictation.onText = { [weak self] text in
      guard let self else { return }
      // the log keeps a dictation's length, not its words: History already holds them, in the app
      dlog("dictation", [.init("chars", .i(text.count)), .init("words", .i(text.split(whereSeparator: \.isWhitespace).count))])
      if let id = documentID { dictatedFields.insert(id) }
      edit { $0.insertFinished(text) }
      // the text usually comes while the panel still shows the wait; the stop time is then the panel's
      // (stoppedAt is set only once Done was tapped or the wait shown, so it may still read .listening when the
      // app went straight to idle)
      let from = panel.isHidden ? waitEndedFrom : (cancelled ? nil : panel.stoppedAt)
      waitEndedFrom = nil
      if let from {  // stop times are cleared per request, so any wait, however long, is this dictation's
        doneIn = Date().timeIntervalSince(from)
        if panel.isHidden { showDoneIn() }  // otherwise once the panel closes
      }
    }
    dictation.onState = { [weak self] state in self?.showDictation(state) }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadSettings()
    applyDebugLog()
    applyTraits()
    engine.resync()
    refresh()
    emojiPanel?.reload()  // the default skin tone may have changed in the app meanwhile
    emojiSearch?.refresh()
    dictation.attach()
    if let p = Settings.shared.previewRecording {
      if p == "done" {
        bar.showNotice(DictationState.doneLabel(elapsed: 1.4), for: 600)  // UI tests: the bar once the text is in
      } else {
        panel.preview = true
        showDictation(DictationState(rawValue: p).flatMap { $0 == .listening ? nil : $0 } ?? .listening)
      }
    }
    // tells the app's setup list the keyboard is on with Full Access; without it the keyboard cannot write here
    if hasFullAccess { Settings.shared.keyboardFullAccessSeen = Date() }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    releaseEdgeTouches()
  }

  /// iOS holds back touches within about 30 pt of the screen's left and right edges while its own edge gestures
  /// decide whether a swipe is starting, so q, a, p, l, delete and 123 act late: a debug log from an iPhone 17 Pro
  /// (build 123) has delete acting 96 ms after the touch there against 19 ms elsewhere, and character keys 38 ms
  /// after the lift against 20 ms. The recognisers that hold the touches sit on the keyboard's window; told not
  /// to delay them, they still recognise their own swipes. The log's `edge-gates` line says how many there were
  /// (`recognisers` -1 or 0 means iOS holds the touches somewhere this process cannot reach), and kb_log_report.py's touch delivery
  /// shows whether the delay went.
  private func releaseEdgeTouches() {
    let gates = view.window?.gestureRecognizers?.filter(\.delaysTouchesBegan) ?? []
    gates.forEach { $0.delaysTouchesBegan = false }
    dlog("edge-gates", [.init("recognisers", .i(view.window?.gestureRecognizers?.count ?? -1)), .init("released", .i(gates.count))])
  }

  /// The bar's note when a word kept on the keyboard goes into the v2t dictionary, which dictation spells from too.
  static func addedLabel(_ word: String) -> String { "Added “\(word)” to your dictionary" }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    dictation.detach()
    dlog("disappear")
    debugLog?.flush(wait: true)  // iOS may end a closed keyboard before a queued write runs
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
    dlog("page", [.init("page", .s("\(page)")), .init("form", .s("\(layout.form)")), .init("width", .d(Double(layout.width)))])
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
    logHost("text")
    lettersIfHostEmptiedField()
    refresh()
  }

  override func selectionDidChange(_ textInput: UITextInput?) {
    super.selectionDidChange(textInput)
    latencyLog.debug("host selectionDidChange engineEditing=\(self.engineEditing, privacy: .public)")
    guard !engineEditing else { return }
    inputEpoch += 1
    engine.resync()
    logHost("selection")
    lettersIfHostEmptiedField()
    refresh()
  }

  // MARK: debug log

  /// Starts or stops the debug log as the app's switch says. The keyboard reads the switch from the App Group,
  /// which iOS opens to it only with Full Access: without it the switch reads off and nothing is recorded. When it
  /// can read the switch but not write there, the log goes to the keyboard's own container instead.
  private func applyDebugLog() {
    // only for an install the app has found may use Debugging: not an App Store build that replaced a TestFlight
    // one with the log on, before v2t is opened (a path compare, no StoreKit call while the keyboard appears)
    let install = DebuggingVisibility.install(of: Bundle.main.bundleURL)
    guard let until = DebuggingVisibility.keyboardLogUntil(settings: .shared, thisInstall: install) else {
      debugLog?.stop()
      setDebugLog(nil)
      return
    }
    if debugLog == nil {
      let group = hasFullAccess ? KeyboardLogStore.groupDirectory : nil
      let writable = group.map { (try? FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)) != nil } ?? false
      setDebugLog(KeyboardDebugLog(directory: writable ? group! : KeyboardLogStore.localDirectory))
    }
    debugLog?.start(until: until)
    dlog("appear", [.init("fullAccess", .b(hasFullAccess)), .init("store", .s(debugLog?.directory == KeyboardLogStore.localDirectory ? "keyboard" : "group")),
                    .init("layout", .s(language.rawValue)), .init("languages", .list(engine.suggester.lexicons.map { .s($0.language) })),
                    .init("width", .d(Double(view.bounds.width))), .init("form", .s("\(keyboardView.layout.form)")),
                    .init("wall", .s(Date().ISO8601Format())),  // anchors the uptime clock, which restarts with the phone
                    .init("version", .s(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))])
    loggedField = nil  // the field gets its line again, after this one
    typedSinceHost = false
  }

  /// The field the log last described, so each field gets one line.
  private var loggedField: UUID?

  private func setDebugLog(_ log: KeyboardDebugLog?) {
    debugLog = log
    keyboardView.debugLog = log
    proxy.log = log
    proxy.redact = { [weak self] in self?.fieldRedacted == true }
    loggedBar = []
    debugSkip = nil
    engine.onEvent = log.map { log in
      { [weak self] event in
        // the words of a field a dictation went into may be dictated ones: the decision is kept, the words not
        if self?.fieldRedacted == true { log.log(event.name, [.init("redacted", .b(true))]); return }
        switch event {
        case .autocorrected(let o, let r): log.log("autocorrect", [.init("from", .s(o)), .init("to", .s(r))])
        case .revertOffered(let o, let r): log.log("revert-offer", [.init("from", .s(o)), .init("to", .s(r))])
        case .reverted(let o, let r, let how): log.log("revert", [.init("from", .s(o)), .init("to", .s(r)), .init("how", .s(how))])
        case .picked(let w, let replaced): log.log("picked", [.init("word", .s(w)), .init("replaced", .s(replaced))])
        case .swiped(let w, let alts): log.log("swiped", [.init("word", .s(w)), .init("alternatives", .list(alts.map { .s($0) }))])
        }
      }
    }
    bar.showsDebugDot = log?.isOn == true && debugSkip == nil
  }

  /// One debug log line, when the log is on; `fields` is only built then.
  private func dlog(_ event: String, _ fields: @autoclosure () -> [LogField] = [], at t: TimeInterval? = nil) {
    guard let log = debugLog, log.isOn else { return }
    log.log(event, fields(), at: t)
  }

  /// The host changed the text or moved the cursor: how much text is before the cursor, as far as the engine
  /// reads it (TypingContext's last 160 characters), but not the text: it may hold dictated words, and a keyboard
  /// reopened after a dictation has no way to tell (#162).
  private func logHost(_ kind: String) {
    typedSinceHost = false
    dlog("host", [.init("kind", .s(kind)), .init("chars", .i(min(160, (textDocumentProxy.documentContextBeforeInput ?? "").count)))])
  }

  /// Fields the log never records. iOS never shows a third-party keyboard in a secure text field (it swaps in its
  /// own), so these are the fields that ask for a password, a one-time code or card details through their content
  /// type. keyboardType has no password or card value, so it marks nothing on its own.
  static func unloggedReason(_ p: UITextDocumentProxy) -> String? {
    if p.isSecureTextEntry == true { return "secure" }
    guard let type = p.textContentType ?? nil else { return nil }
    switch type {
    case .password, .newPassword: return "password"
    case .oneTimeCode: return "one-time-code"
    case .creditCardNumber, .creditCardSecurityCode, .creditCardExpiration, .creditCardExpirationMonth, .creditCardExpirationYear,
         .creditCardName, .creditCardGivenName, .creditCardMiddleName, .creditCardFamilyName, .creditCardType:
      return "card"
    default: return nil
    }
  }

  /// Pauses the log in a field it must not record, and resumes it after.
  private func applyDebugSkip() {
    guard let log = debugLog else { return }
    let reason = Self.unloggedReason(textDocumentProxy)
    guard reason != debugSkip else { return }
    if let reason {
      log.log("skip", [.init("reason", .s(reason))])  // the last line before the pause: says why, records nothing of the field
      log.suspend(true)
    } else {
      log.suspend(false)
      log.log("resume")
    }
    debugSkip = reason
    bar.showsDebugDot = log.isOn
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
    applyDebugSkip()
    if let log = debugLog, log.isOn, let id = documentID, id != loggedField {
      loggedField = id
      log.log("field", [.init("keyboardType", .i(type.rawValue)), .init("contentType", .s(p.textContentType??.rawValue ?? "")),
                        .init("autocorrect", .b(t.autocorrect)), .init("capitalization", .s("\(t.capitalization)")),
                        .init("return", .i((p.returnKeyType ?? .default).rawValue))])
    }
    keyboardView.returnLabel = Self.returnLabel(p.returnKeyType ?? .default, language)
    let numeric = [.numberPad, .decimalPad, .numbersAndPunctuation, .phonePad, .asciiCapableNumberPad].contains(type)
    fieldNumeric = numeric
    if let page = KeyboardPage.forField(numeric: numeric, current: keyboardView.layout.page, emojiSearch: emojiSearch != nil) {
      relayout(page: page)
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
    bar.clearNotice()  // typing again (by touch or VoiceOver): the suggestions come back
    engineEditing = true
    body(engine)
    engineEditing = false
    refresh()
    latencyLog.log("\(name, privacy: .public) \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000), privacy: .public) ms")
  }

  /// Whether the field held text at the last refresh, and whether its keyboard type is a numeric one: what
  /// `KeyboardPage.afterHostEdit` needs when the host changes the text.
  private var hostText = HostTextWatch()
  private var fieldNumeric = false

  /// The app emptied a field that had text (a sent message, a typing exercise's next sentence): back to
  /// letters. Called from both host callbacks, before either refreshes, since iOS sends them in either order.
  private func lettersIfHostEmptiedField() {
    let emptied = hostText.emptied(hasText: textDocumentProxy.hasText)
    if let page = KeyboardPage.afterHostEdit(emptied: emptied, numeric: fieldNumeric, current: keyboardView.layout.page,
                                             emojiSearch: emojiSearch != nil) {
      relayout(page: page)
    }
  }

  private func refresh() {
    hostText.note(hasText: textDocumentProxy.hasText)
    // search has its own shift, off unless tapped, and types the shifted mark only (EmojiIndex folds case)
    keyboardView.shift = emojiSearch == nil ? engine.shift : (searchShift ? .on : .off)
    keyboardView.shiftManual = emojiSearch == nil ? engine.shiftManual : true
    let suggestions = engine.suggestions(), pending = engine.pendingAutocorrection
    bar.show(suggestions, pending: pending)
    bar.showsDebugDot = debugLog?.isOn == true  // off once the 24 hours are up, and in fields it skips
    if let log = debugLog, log.isOn {
      let words = suggestions.map(\.word) + [pending ?? ""]
      if words != loggedBar {
        loggedBar = words
        if fieldRedacted { log.log("bar", [.init("count", .i(suggestions.count)), .init("redacted", .b(true))]); return }
        log.log("bar", [.init("words", .list(suggestions.map { .s($0.word) })), .init("kinds", .list(suggestions.map { .s("\($0.kind)") })),
                        .init("bold", pending.map { .s($0) } ?? .null)])
      }
    }
  }

  // MARK: KeyboardViewDelegate

  func keyboardViewKeyDown(_ v: KeyboardView) {
    bar.clearNotice()  // any key touch, shift and page keys too, brings the suggestions back
    if hasFullAccess { haptics.impactOccurred(intensity: 0.6) }
    UIDevice.current.playInputClick()
  }

  func keyboardView(_ v: KeyboardView, typed text: String, at point: CGPoint?) {
    typedSinceHost = true
    dlog("key", [.init("text", .s(text)), .init("p", point.map { .pt($0) } ?? .null), .init("search", .b(emojiSearch != nil))])
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
    bar.clearNotice()  // every key action, VoiceOver's shift and page keys included, brings the suggestions back
    dlog("act", [.init("a", .s("\(action)")), .init("search", .b(emojiSearch != nil))])
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
    dlog("act", [.init("a", .s(wholeWord ? "deleteWord" : "delete")), .init("search", .b(emojiSearch != nil))])
    if let s = emojiSearch { s.deleteBackward(); return }
    edit { wholeWord ? $0.deleteWord() : $0.delete() }
  }

  func keyboardView(_ v: KeyboardView, moveCursor by: Int) {
    guard emojiSearch == nil else { return }  // the space-bar trackpad must not move the document's cursor
    dlog("cursor", [.init("by", .i(by))])
    inputEpoch += 1
    engineEditing = true
    textDocumentProxy.adjustTextPosition(byCharacterOffset: by)
    engineEditing = false
    engine.resync()
    refresh()
  }

  func keyboardView(_ v: KeyboardView, swiped trace: [CGPoint]) {
    // search takes taps only; the line tells the report this lifted swipe has no decode coming
    guard emojiSearch == nil else { dlog("swipe", [.init("ignored", .s("emoji search"))]); return }
    var decoder = MultiSwipeDecoder(decoders)
    decoder.languagePrior = engine.suggester.languagePrior  // the language last written in, as the bar's
    let t0 = CACurrentMediaTime()
    let epoch = inputEpoch, document = documentID
    // the words before the swipe pick the language and promote the words that usually come next
    let context = textDocumentProxy.documentContextBeforeInput ?? ""
    // decided now: by the time the decode returns, focus may have moved out of a field the log must skip
    let loggable = debugLog?.isOn == true, liftedAt = ProcessInfo.processInfo.systemUptime
    decodeQueue.async {
      defer { latencyLog.log("swipe-decode \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000), privacy: .public) ms") }
      let scored = decoder.decodeScored(trace, context: context, limit: 4)
      let words = scored.map(\.word), ms = (CACurrentMediaTime() - t0) * 1000
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let applies = !words.isEmpty && self.inputEpoch == epoch && self.emojiSearch == nil
          && document != nil && self.documentID == document  // nil once the keyboard has closed
        if loggable { self.dlog("swipe", [.init("points", .i(trace.count)), .init("trace", .list(KeyboardDebugLog.sample(trace, limit: 48).map { .pt($0) })),
                            .init("candidates", .list(scored.map { .obj([.init("w", .s($0.word)), .init("s", .d($0.score))]) })),
                            .init("applied", .b(applies)), .init("decodeMs", .d(ms))], at: liftedAt) }
        guard applies else { return }
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
      resizeBar()  // the keyboard grows by the panel's search row
      view.layoutIfNeeded()  // a new panel gets its size before it picks the section to open at
      p.show()
      p.isHidden = !panel.isHidden  // a recording already on screen stays on top until it ends
    } else {
      emojiPanel?.removeFromSuperview()
      emojiPanel = nil
      resizeBar()
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
    p.onEmoji = { [weak self] e in
      self?.dlog("emoji", [.init("emoji", .s(e)), .init("from", .s("panel"))])
      self?.edit("emoji") { $0.emoji(e) }
    }
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
      dlog("emoji", [.init("emoji", .s(e)), .init("from", .s("search"))])
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
    applyTraits()  // a numbers field's page comes back, under the panel, once search no longer owns the keys
    showEmoji(true)
  }

  private func resizeBar() {
    barHeightConstraint?.constant = barHeight
    heightConstraint?.constant = barHeight + keyboardView.layout.height
    refresh()
  }

  // MARK: dictation

  private func startDictation() {
    // a new request, whether or not its listening state is ever seen here (the app hand-off): no old timing
    waitEndedFrom = nil
    doneIn = nil
    dictation.toggle()
  }

  /// Covers the keys with the recording panel while dictating; the keys come back once the text is in.
  private func showDictation(_ state: DictationState) {
    let active = [.listening, .transcribing, .cleaningUp].contains(state)
    if state == .listening { waitEndedFrom = nil; doneIn = nil }
    // the wait after Done ended before its text came: keep when it began, for the bar's total
    if !active, !panel.isHidden, !cancelled { waitEndedFrom = panel.stoppedAt }
    if !active { cancelled = false }
    guard (active && !cancelled) || panel.preview else {
      setPanel(visible: false)
      showDoneIn()
      return
    }
    view.layoutIfNeeded()
    let layout = keyboardView.layout
    let row = layout.keys.filter { $0.row == layout.metrics.rows - 1 }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    panel.show(state, bottomRow: keyboardView.convert(row, to: panel))
    // show() can find the app gone and hide the panel at once (onStateChange): then the keys must come back
    setPanel(visible: !panel.isHidden)
    showDoneIn()
  }

  /// "Done in 1.4 s" in the bar, once, when the text is in and the panel has closed.
  private func showDoneIn() {
    guard let seconds = doneIn, panel.isHidden else { return }
    doneIn = nil
    waitEndedFrom = nil  // this dictation's stop time is spent
    bar.showNotice(DictationState.doneLabel(elapsed: seconds))
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
/// With the debug log on, records every insert and delete it makes in the document.
final class ProxyAdapter: TextProxy {
  private weak var controller: UIInputViewController?
  var log: KeyboardDebugLog?
  /// True in a field a dictation went into: inserts are logged by length only.
  var redact: () -> Bool = { false }
  init(_ c: UIInputViewController) { controller = c }
  var documentContextBeforeInput: String? { controller?.textDocumentProxy.documentContextBeforeInput }
  func insertText(_ text: String) {
    if let log, log.isOn { log.log("ins", redact() ? [.init("chars", .i(text.count))] : [.init("text", .s(text))]) }
    controller?.textDocumentProxy.insertText(text)
  }
  func deleteBackward() {
    if let log, log.isOn { log.log("del") }
    controller?.textDocumentProxy.deleteBackward()
  }
}

/// Loads the bundled lexicons, memory-mapped.
enum LexiconStore {
  static func load(_ lang: KeyboardLanguage) -> Lexicon? {
    guard let url = Bundle.main.url(forResource: lang.rawValue, withExtension: "v2tlex", subdirectory: "lexicons") else { return nil }
    return try? Lexicon(contentsOf: url, language: lang.rawValue)
  }
}
