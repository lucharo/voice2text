import SwiftUI
import UniformTypeIdentifiers
import V2TKeyboardCore

@main struct V2TApp: App {
  @StateObject private var history: History
  @StateObject private var dictionary: PersonalDictionary
  @StateObject private var dictation: DictationService
  @StateObject private var iCloud: ICloudSync

  init() {
    // UI tests pick the keyboard layout through the launch environment
    if let layout = ProcessInfo.processInfo.environment["V2T_LAYOUT"], let l = KeyboardLanguage(rawValue: layout) {
      Settings.shared.layoutLanguage = l
      Settings.shared.defaults.removeObject(forKey: "learnedWords")  // each UI test starts with nothing learned
    }
    let env = ProcessInfo.processInfo.environment
    // the keyboard UI tests start with an empty dictionary: a word an earlier test kept ("Teh") would stop
    // the next one's autocorrect (#147)
    if env["V2T_RESET_DICTIONARY"] == "1" { try? PersonalDictionary().save(PersonalDictionary.header) }
    Settings.shared.previewRecording = env["V2T_PREVIEW_RECORDING"]  // never left on after a UI test
    Settings.shared.previewGlobeKey = env["V2T_PREVIEW_GLOBE"].map { $0 == "1" }
    // UI tests start the emoji keyboard from a known skin tone (0 yellow); the keyboard's own tones give way to it
    if let t = env["V2T_SKIN_TONE"].flatMap(Int.init) { Settings.shared.emojiSkinTone = SkinTone(rawValue: t) }
    // the debug log UI test starts with the log off and empty, and leaves it off
    if env["V2T_KEYBOARD_LOG_OFF"] == "1" { Settings.shared.keyboardDebugLogUntil = nil }
    // UI tests start as after install ("1": About v2t opens by itself) or with it already seen ("0")
    if let first = env["V2T_FIRST_LAUNCH"] { Settings.shared.aboutShown = first != "1" }
    if env["V2T_RESET_KEYBOARD_LOG"] == "1" {
      Settings.shared.keyboardDebugLogUntil = nil
      if let dir = KeyboardLogStore.groupDirectory { KeyboardDebugLog.clear(in: dir) }
    }
    let h = History(), d = PersonalDictionary()
    _history = StateObject(wrappedValue: h)
    _dictionary = StateObject(wrappedValue: d)
    _dictation = StateObject(wrappedValue: DictationService(recommendation: .current, history: h, dictionary: d))
    _iCloud = StateObject(wrappedValue: ICloudSync(dictionary: d))
  }

  var body: some Scene {
    WindowGroup {
      HomeView()
        .environmentObject(history)
        .environmentObject(dictionary)
        .environmentObject(dictation)
        .environmentObject(iCloud)
        // UI tests that start with nothing learned (V2T_LAYOUT) run without iCloud: the Simulator's store keeps
        // what an earlier test synced and would bring it back
        .task { if ProcessInfo.processInfo.environment["V2T_LAYOUT"] == nil { iCloud.start() } }
        .onOpenURL { url in
          if url.scheme == "v2t", url.host == "dictate" { dictation.handleKeyboardLaunch() }
        }
        .task { await dictation.loadModelIfOnDevice() }  // downloads only when the user taps Download (#124)
    }
  }
}

struct HomeView: View {
  @EnvironmentObject var dictation: DictationService
  @EnvironmentObject var history: History
  @Environment(\.scenePhase) private var scenePhase
  @State private var tryText = ""
  @State private var keyboardSeen = Settings.shared.keyboardFullAccessSeen
  /// About v2t over the setup list, once after install; dismissing it shows the setup list.
  @State private var showAbout = !Settings.shared.aboutShown

  var body: some View {
    NavigationStack {
      List {
        Section("Set up") {
          SetupRow(number: 1, title: "Add the v2t keyboard",
                   detail: keyboardSeen == nil ? "Settings › v2t › Keyboards › turn on v2t." : "Done: the v2t keyboard is on.",
                   done: keyboardSeen != nil) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
          SetupRow(number: 2, title: "Allow Full Access",
                   detail: keyboardSeen == nil
                     ? "Lets the keyboard ask v2t to dictate. Nothing you type leaves the \(dictation.recommendation.deviceName). Then open the v2t keyboard once in Try it below: iOS only lets v2t see both steps through the keyboard."
                     : "Done: the keyboard last opened with Full Access \(keyboardSeen!.formatted(date: .abbreviated, time: .shortened)).",
                   done: keyboardSeen != nil) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
          ModelRow()
        }
        Section("Try it") {
          TextField("Type, swipe or dictate here", text: $tryText, axis: .vertical)
            .lineLimit(3...6)
            // UI tests try the keyboard in a numbers-and-punctuation field (V2T_TRY_KEYBOARD=numbers) whose app
            // rewrites the text after each change, as a field that formats its input does: it adds a "#"
            .keyboardType(ProcessInfo.processInfo.environment["V2T_TRY_KEYBOARD"] == "numbers" ? .numbersAndPunctuation : .default)
            .onChange(of: tryText) {
              // after the edit's own update, which a change made inside it would be lost to
              if ProcessInfo.processInfo.environment["V2T_TRY_KEYBOARD"] == "numbers", !tryText.isEmpty, !tryText.hasSuffix("#") {
                DispatchQueue.main.async { tryText += "#" }
              }
            }
            .accessibilityIdentifier("v2t.try")
        }
        Section("Dictation") {
          WarmRow()
          MicrophoneRow()
          CleanupRow()
          Picker("Speech language", selection: Binding(get: { Settings.shared.speechLanguage }, set: { Settings.shared.speechLanguage = $0 })) {
            Text("English").tag("en")
            Text("Español").tag("es")
            Text("Detect").tag("auto")
          }
          NavigationLink("Dictionary") { DictionaryView() }
          NavigationLink("History (\(history.items.count))") { HistoryView() }
        }
        Section("This \(dictation.recommendation.deviceName)") { RecommendationCard(rec: dictation.recommendation) }
        Section("Storage") { StorageRows() }
        Section("Keyboard") { NavigationLink("Languages and typing") { KeyboardSettingsView() } }
        Section {
          NavigationLink("About v2t") { AboutView() }
            .accessibilityIdentifier("v2t.about.open")
        }
      }
      .navigationTitle("v2t")
      // a readable column on an iPad, as Settings keeps its rows; no effect at iPhone widths
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
      .background(Color(.systemGroupedBackground))
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      keyboardSeen = Settings.shared.keyboardFullAccessSeen
      dictation.refreshRecommendation()
      dictation.refreshModelStorage()
    }
    .onChange(of: tryText) { keyboardSeen = Settings.shared.keyboardFullAccessSeen }
    .fullScreenCover(isPresented: $dictation.cameFromKeyboard) { KeyboardHandoffView() }
    // the keyboard's mic opened v2t before it was ever opened: recording comes first, About waits for a later launch
    .sheet(isPresented: Binding(get: { showAbout && !dictation.cameFromKeyboard }, set: { showAbout = $0 }),
           onDismiss: { if !dictation.cameFromKeyboard { Settings.shared.aboutShown = true } }) {
      AboutView { showAbout = false }
    }
  }
}

struct SetupRow: View {
  let number: Int, title: String, detail: String, done: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
          .font(.title2).foregroundStyle(done ? .green : .accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundStyle(.primary)
          Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct ModelRow: View {
  @EnvironmentObject var dictation: DictationService
  var body: some View {
    if dictation.recommendation.tier == .notSupported { notSupported } else { model }
  }

  /// A13 and A14 devices: no download to offer, only why (the owner's tiers, 2026-11-12).
  private var notSupported: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "mic.slash").font(.title2).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text("Dictation").foregroundStyle(.primary)
        Text(dictation.recommendation.notSupportedMessage).font(.footnote).foregroundStyle(.secondary)
        Text(dictation.recommendation.notSupportedReason).font(.footnote).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("v2t.model.notSupported")
  }

  private var model: some View {
    HStack(alignment: dictation.engineState == .notDownloaded ? .center : .top, spacing: 12) {
      Image(systemName: icon).font(.title2).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 4) {
        Text("Speech model").foregroundStyle(.primary)
        Text("\(dictation.recommendation.speechName) · \(dictation.recommendation.downloadMB) MB, once")
          .font(.footnote).foregroundStyle(.secondary)
        switch dictation.engineState {
        case .downloading(let p):
          ProgressView(value: p) { Text("Downloading \(Int(p * 100))%").font(.footnote) }
        case .loading: Text("Preparing for the Neural Engine…").font(.footnote)
        case .failed(let e):
          Text(e).font(.footnote).foregroundStyle(.red)
          Button("Try again") { Task { await dictation.prepareModel() } }
        case .ready: Text("Ready. Transcription runs on this \(dictation.recommendation.deviceName), offline.").font(.footnote).foregroundStyle(.secondary)
        case .notDownloaded:
          Text("Needed for the mic. Typing works without it.").font(.footnote).foregroundStyle(.secondary)
        }
        if dictation.recommendation.tier == .untested {
          Text(dictation.recommendation.untestedLine).font(.footnote).foregroundStyle(.orange)
            .accessibilityIdentifier("v2t.model.untested")
        }
      }
      // the text takes every point the button leaves, so the row has no gap between them
      .frame(maxWidth: .infinity, alignment: .leading)
      if dictation.engineState == .notDownloaded {
        // a real button at the row's end (a bordered style also keeps the rest of the row from acting as it)
        Button { Task { await dictation.prepareModel() } } label: { Label("Download", systemImage: "arrow.down") }
          .labelStyle(.titleAndIcon).fixedSize()  // never wrapped to "Down-load" in a narrow row
          .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
          .accessibilityLabel("Download, \(dictation.recommendation.downloadMB) MB")
          .accessibilityIdentifier("v2t.model.download")
      }
    }
  }
  var icon: String { dictation.engineState == .ready ? "checkmark.circle.fill" : "3.circle" }
  var color: Color { dictation.engineState == .ready ? .green : .accentColor }
}

struct WarmRow: View {
  @EnvironmentObject var dictation: DictationService
  var body: some View {
    Toggle(isOn: Binding(get: { dictation.state != .needsApp }, set: { $0 ? dictation.warmUp() : dictation.coolDown() })) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Mic ready for the keyboard")
        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
        if let mic = dictation.microphone { MicrophoneLabel(mic: mic) }
      }
    }
    .accessibilityIdentifier("v2t.warm")
    if dictation.state != .needsApp {
      Button("Stop microphone session", role: .destructive) { dictation.coolDown() }
        .accessibilityIdentifier("v2t.stopMic")
    }
  }
  var subtitle: String {
    guard dictation.state != .needsApp else { return "Off: the keyboard's mic opens v2t once to turn it on." }
    if let until = dictation.warmUntil { return "On: dictate from any app until \(until.formatted(date: .omitted, time: .shortened)), 15 minutes after your last dictation unless changed in Keyboard settings. The orange dot shows while it's on; only what you say between the mic taps is kept." }
    return "Dictate from any app until you turn this off. The orange dot shows while it's on."
  }
}

/// Apple Intelligence cleanup on or off. Off, or where Apple Intelligence is unavailable, a dictation keeps the
/// words as heard, with only the dictionary's replacements applied.
struct CleanupRow: View {
  @EnvironmentObject var dictation: DictationService
  @AppStorage("cleanupEnabled", store: Settings.shared.defaults) private var cleanup = true
  var available: Bool { dictation.recommendation.cleanup == .appleIntelligence }
  var body: some View {
    Toggle(isOn: $cleanup) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Clean up with Apple Intelligence")
        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .disabled(!available)
    .accessibilityIdentifier("v2t.cleanup")
  }
  var subtitle: String {
    guard available else { return dictation.recommendation.cleanupUnavailable }
    return cleanup
      ? "On: fixes punctuation and drops fillers on the \(dictation.recommendation.deviceName), keeping your words and dictionary spellings."
      : "Off: you get the words as heard, plus your dictionary's replacements."
  }
}

struct RecommendationCard: View {
  /// The FAQ answer on the iPhone models we measured and why this one ships.
  static let evaluation = URL(string: "https://v2t.luischav.es/faq/#what-would-v2t-on-an-iphone-use")!
  let rec: Recommendation
  @AppStorage("cleanupEnabled", store: Settings.shared.defaults) private var cleanup = true
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(rec.speechName, systemImage: "waveform").font(.subheadline.weight(.semibold))
      Label(rec.cleanup == .appleIntelligence && !cleanup ? "Cleanup: off (turned off above)" : rec.cleanupName, systemImage: "sparkles").font(.subheadline)
      Text(rec.reason).font(.footnote).foregroundStyle(.secondary)
      if !rec.measured { Text("Untested on this \(rec.deviceName) model.").font(.footnote).foregroundStyle(.orange) }
      // one model that just works, picked from our tests, rather than a choice to make; the tests are public
      Link("How we chose this model", destination: Self.evaluation).font(.footnote)
        .accessibilityIdentifier("v2t.model.evaluation")
    }
    .padding(.vertical, 4)
  }
}

/// Which microphone dictation uses: this iPhone's by default, or a connected headset's or AirPods'.
struct MicrophoneRow: View {
  @EnvironmentObject var dictation: DictationService
  @State private var choice = Settings.shared.microphoneChoice
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Picker("Microphone", selection: $choice) {
        Text("This \(dictation.recommendation.deviceName)").tag(MicrophoneChoice.iPhone)
        Text("Connected headset").tag(MicrophoneChoice.connected)
      }
      .accessibilityIdentifier("v2t.microphoneChoice")
      // a choice made mid-dictation could only apply by restarting the session, which may be in the background
      .disabled(!DictationService.allowsMicrophoneChange(dictation.state))
      Text(choice == .iPhone
        ? "Speak towards your \(dictation.recommendation.deviceName). AirPods and other headphones keep playing music in full quality."
        : "Uses AirPods or a wired headset when one is connected. With AirPods, music drops to call quality while the mic is ready.")
        .font(.footnote).foregroundStyle(.secondary)
    }
    .onChange(of: choice) {
      Settings.shared.microphoneChoice = choice
      dictation.applyMicrophoneChoice()
    }
  }
}

/// The input the session records from, by the name iOS gives it, so a headset or car taking over is obvious.
struct MicrophoneLabel: View {
  let mic: Microphone
  var body: some View {
    // the icon inside the text: as a Label in the switch's row it drew on a line of its own
    Text("\(Image(systemName: "mic.fill")) Recording from \(mic.name)")
      .font(.footnote).foregroundStyle(.secondary)
      .accessibilityLabel("Recording from \(mic.name)")
      .accessibilityIdentifier("v2t.microphone")
  }
}

/// What v2t keeps on the device, with a button to remove each: the speech model, and the dictation history.
struct StorageRows: View {
  @EnvironmentObject var dictation: DictationService
  @EnvironmentObject var history: History
  @State private var confirmModel = false
  @State private var confirmHistory = false

  static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent("Speech model", value: dictation.modelBytes == 0 ? "Not downloaded"
        : dictation.modelOnDevice ? Self.size(dictation.modelBytes) : "\(Self.size(dictation.modelBytes)), incomplete")
        .accessibilityIdentifier("v2t.storage.model")
      Button("Delete speech model", role: .destructive) { confirmModel = true }
        .disabled(!dictation.canDeleteModel)
        .accessibilityIdentifier("v2t.storage.deleteModel")
        .confirmationDialog("Delete the speech model?", isPresented: $confirmModel, titleVisibility: .visible) {
          Button("Delete", role: .destructive) { Task { await dictation.deleteModel() } }
        } message: {
          Text("Dictation stops working until you download it again (\(dictation.recommendation.downloadMB) MB).")
        }
    }
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent("Dictations", value: !history.hasFiles ? "None" : "\(history.items.count) · \(Self.size(history.bytes))")
        .accessibilityIdentifier("v2t.storage.history")
      Text("Text only. Audio is never saved.")
        .font(.footnote).foregroundStyle(.secondary)
      Button("Clear History", role: .destructive) { confirmHistory = true }
        .disabled(!history.hasFiles)
        .accessibilityIdentifier("v2t.storage.clearHistory")
        .confirmationDialog("Delete all \(history.items.count) dictations?", isPresented: $confirmHistory, titleVisibility: .visible) {
          Button("Delete all", role: .destructive) { dictation.clearHistory() }
        }
    }
    if let e = dictation.storageError { Text(e).font(.footnote).foregroundStyle(.red) }
  }
}

/// Shown when the keyboard's mic opened v2t: recording has started; the user goes back to keep talking.
struct KeyboardHandoffView: View {
  @EnvironmentObject var dictation: DictationService
  /// The mic opened v2t with no speech model on the device: this screen offers the download instead of recording.
  @State private var neededModel = false
  var body: some View {
    Group { if dictation.recommendation.tier == .notSupported { notSupported } else if neededModel { modelNeeded } else { handoff } }
      .onAppear { neededModel = !dictation.canDictate }
      // the model can fail to load after this screen appeared (damaged files): stop telling the user to keep
      // talking, and show Try again instead
      .onChange(of: dictation.engineState) { _, state in
        guard case .failed = state, !neededModel else { return }
        if dictation.state == .listening { dictation.stop() }
        neededModel = true
      }
  }

  /// The keyboard's mic on a device whose tier is not supported yet: the same words as the app's model row.
  private var notSupported: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "mic.slash").font(.system(size: 64)).foregroundStyle(.secondary)
      Text(dictation.recommendation.notSupportedMessage).font(.title2.bold())
        .multilineTextAlignment(.center).padding(.horizontal, 32)
      Text(dictation.recommendation.notSupportedReason)
        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
      Spacer()
      Button("Close") { dictation.cameFromKeyboard = false }.padding(.bottom, 32)
    }
    .accessibilityIdentifier("v2t.handoff.notSupported")
  }

  private var modelNeeded: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: dictation.engineState == .ready ? "checkmark.circle.fill" : "arrow.down.circle")
        .font(.system(size: 64)).foregroundStyle(dictation.engineState == .ready ? .green : .accentColor)
      Text(dictation.engineState == .ready ? "Speech model ready"
           : !dictation.modelOnDevice ? "Download the speech model"
           : dictation.engineState == .loading ? "Preparing the speech model" : "The speech model didn't load").font(.largeTitle.bold())
        .multilineTextAlignment(.center)
      Text(dictation.engineState == .ready
        ? "Go back to your app and tap the mic again."
        : dictation.modelOnDevice && dictation.engineState == .loading
          ? "The first time, v2t prepares the speech model for this \(dictation.recommendation.deviceName). Stay in v2t until it's ready."
          : "v2t turns speech into text on this \(dictation.recommendation.deviceName), so the keyboard's mic needs the speech model first.")
        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
      if dictation.engineState != .ready { ModelRow().padding(.horizontal, 32) }
      Spacer()
      Button("Close") { dictation.cameFromKeyboard = false }.padding(.bottom, 32)
    }
    .accessibilityIdentifier("v2t.handoff.modelNeeded")
  }

  private var handoff: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: dictation.state == .listening ? "waveform" : "mic.fill")
        .font(.system(size: 64)).foregroundStyle(.red).symbolEffect(.variableColor, isActive: dictation.state == .listening)
      Text(dictation.state == .listening ? "Listening" : "Mic is ready").font(.largeTitle.bold())
      if let mic = dictation.microphone { MicrophoneLabel(mic: mic) }
      // three short lines rather than one paragraph, and ◀ held to its words, so no line starts or ends on it
      VStack(spacing: 10) {
        Text(dictation.state == .listening ? "Go back to your app and keep talking." : "Go back to your app.")
          .font(.title3.weight(.medium))
        Group {
          Text("Tap\u{00A0}◀\u{00A0}at the top left, or swipe right along the bottom edge.")
          Text(dictation.state == .listening ? "Then tap Done on the v2t keyboard." : "The keyboard's mic now records without coming here.")
        }
        .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center).padding(.horizontal, 32)
      Image(systemName: "arrow.right").font(.title).foregroundStyle(.secondary)
      Spacer()
      Button(dictation.state == .listening ? "Stop and stay here" : "Close") {
        if dictation.state == .listening { dictation.stop() }
        dictation.cameFromKeyboard = false
      }
      .padding(.bottom, 32)
    }
    // no session (it timed out or was turned off, or the microphone never started): the screen's "keyboard
    // records in place" does not hold, so close it, also when it opens that way. Not when the model is what is
    // missing: then this cover switches to the download (or Try again) screen instead.
    .onChange(of: dictation.state, initial: true) { _, state in
      if state == .needsApp, dictation.canDictate { dictation.cameFromKeyboard = false }
    }
  }
}

/// Words to spell exactly, and replacements, as two lists with an add row each. Same file and format as the
/// Mac app; "Edit as text" opens the file itself.
struct DictionaryView: View {
  @EnvironmentObject var dictionary: PersonalDictionary
  @EnvironmentObject var iCloud: ICloudSync
  @Environment(\.scenePhase) private var scenePhase
  @State private var term = ""
  @State private var heard = ""
  @State private var written = ""
  @State private var error: String?

  var body: some View {
    let items = dictionary.items
    List {
      Section {
        ForEach(items.filter { if case .term = $0.kind { true } else { false } }) { item in
          Text(item.line)
        }
        .onDelete { remove($0, from: items.filter { if case .term = $0.kind { true } else { false } }) }
        HStack {
          TextField("Add a name or word", text: $term)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit(addTerm)
            .accessibilityIdentifier("v2t.dict.term")
          Button("Add", action: addTerm).disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("v2t.dict.addTerm")
        }
      } header: { Text("Spell exactly") } footer: {
        Text("Names, products or jargon the recogniser gets wrong. Cleanup spells them as written here, and the keyboard never autocorrects them. A word you keep on the keyboard over its correction is added here.")
      }

      Section {
        ForEach(items.filter { if case .replacement = $0.kind { true } else { false } }) { item in
          if case .replacement(let h, let w) = item.kind {
            HStack { Text(h); Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityLabel("becomes"); Text(w) }
          }
        }
        .onDelete { remove($0, from: items.filter { if case .replacement = $0.kind { true } else { false } }) }
        HStack {
          TextField("Heard", text: $heard).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("v2t.dict.heard")
          Image(systemName: "arrow.right").foregroundStyle(.secondary)
          TextField("Written", text: $written).textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit(addReplacement)
            .accessibilityIdentifier("v2t.dict.written")
          Button("Add", action: addReplacement)
            .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("v2t.dict.addReplacement")
        }
      } header: { Text("Replace") } footer: {
        Text("Applied to every dictation after cleanup, whole words, any capitalisation.")
      }

      Section { NavigationLink("Edit as text") { DictionaryTextView() } }
      Section { ICloudSyncRow() }
    }
    .navigationTitle("Dictionary")
    .onAppear { dictionary.reload() }
    // back from another app, where the keyboard may have added a word (the text editor keeps its own draft)
    .onChange(of: scenePhase) { _, phase in if phase == .active { dictionary.reload() } }
    .alert("Couldn't add that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(error ?? "") }
  }

  func addTerm() {
    do { try dictionary.addTerm(term); term = ""; iCloud.sync() } catch { self.error = error.localizedDescription }
  }

  func addReplacement() {
    do { try dictionary.addReplacement(heard: heard, written: written); heard = ""; written = ""; iCloud.sync() } catch { self.error = error.localizedDescription }
  }

  func remove(_ offsets: IndexSet, from items: [PersonalDictionary.Item]) {
    for i in offsets { try? dictionary.remove(items[i].line) }
    iCloud.sync()
  }
}

/// The dictionary file as text, for pasting a list from the Mac app.
struct DictionaryTextView: View {
  @EnvironmentObject var dictionary: PersonalDictionary
  @EnvironmentObject var iCloud: ICloudSync
  @State private var draft = ""
  @State private var snapshot = ""
  var body: some View {
    TextEditor(text: $draft)
      .font(.body.monospaced())
      .padding(.horizontal, 8)
      .navigationTitle("Dictionary file")
      .onAppear { dictionary.reload(); draft = dictionary.text; snapshot = draft }
      .onDisappear { try? dictionary.saveEdit(draft, from: snapshot); iCloud.sync() }
  }
}

struct HistoryView: View {
  @EnvironmentObject var history: History
  var body: some View {
    List {
      ForEach(history.items) { d in
        VStack(alignment: .leading, spacing: 4) {
          Text(d.text).textSelection(.enabled)
          if let heard = d.heard { Text("Heard: \(heard)").font(.footnote).foregroundStyle(.secondary) }
          if let t = d.timings { Text(t.summary).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
          Text(d.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .swipeActions { Button("Delete", role: .destructive) { try? history.delete(d.id) } }
      }
    }
    .overlay { if history.items.isEmpty { Text("No dictations yet").foregroundStyle(.secondary) } }
    .navigationTitle("History")
    .toolbar { TimingsToolbar() }
  }
}

struct KeyboardSettingsView: View {
  @EnvironmentObject var dictation: DictationService
  @State private var layout = Settings.shared.layoutLanguage
  @State private var bilingual = Settings.shared.suggestionLanguages.count > 1
  @State private var warm = Settings.shared.warmMinutes
  /// 0 is yellow, 1 to 5 the skin tones.
  @State private var skinTone = Settings.shared.emojiSkinTone?.rawValue ?? 0
  var body: some View {
    Form {
      Picker("Layout", selection: $layout) {
        Text("English (QWERTY)").tag(KeyboardLanguage.english)
        Text("Español (con ñ)").tag(KeyboardLanguage.spanish)
      }
      Toggle("Suggest English and Spanish together", isOn: $bilingual)
      Picker("Keep the mic ready for", selection: $warm) {
        Text("5 minutes").tag(5)
        Text("15 minutes").tag(15)
        Text("1 hour").tag(60)
        Text("Until I turn it off").tag(0)
      }
      Section {
        // written on every pick, the one already shown too: picking it again resets the tones picked for
        // single emoji in the keyboard since
        Picker("Emoji skin tone", selection: Binding(get: { skinTone }, set: {
          skinTone = $0
          Settings.shared.emojiSkinTone = SkinTone(rawValue: $0)
        })) {
          Text("👋 Yellow").tag(0)
          ForEach(SkinTone.allCases, id: \.rawValue) { t in Text("👋" + t.modifier).tag(t.rawValue) }
        }
        .accessibilityIdentifier("settings.skinTone")
      } footer: {
        Text("Every emoji with skin tones shows this tone until you pick another for it: touch and hold an emoji in the v2t keyboard. iOS keeps the Apple keyboard's skin tones to itself, so v2t cannot follow them.")
      }
      KeyboardLogSection()
    }
    .navigationTitle("Keyboard")
    .onChange(of: layout) { Settings.shared.layoutLanguage = layout; saveLanguages() }
    .onChange(of: bilingual) { saveLanguages() }
    .onChange(of: warm) {
      Settings.shared.warmMinutes = warm
      dictation.applyWarmSetting()  // a session already on takes the new length from now
    }
  }

  private func saveLanguages() {
    Settings.shared.suggestionLanguages = bilingual ? [layout, layout == .english ? .spanish : .english] : [layout]
  }
}

/// The opt-in keyboard debug log (#162): the switch, when it turns itself off, Export and Clear log.
struct KeyboardLogSection: View {
  @State private var until = KeyboardLogSection.activeUntil
  @State private var size = 0
  private let dir = KeyboardLogStore.groupDirectory

  static var activeUntil: Date? { Settings.shared.keyboardDebugLogUntil.flatMap { $0 > Date() ? $0 : nil } }

  var body: some View {
    Section {
      Toggle("Keyboard debug log", isOn: Binding(get: { until != nil }, set: { on in
        let u = on ? Date().addingTimeInterval(KeyboardLogStore.lifetime) : nil
        Settings.shared.keyboardDebugLogUntil = u
        until = u
      }))
      .accessibilityIdentifier("settings.debugLog")
      if let until {
        Text("On until \(until.formatted(date: .abbreviated, time: .shortened)). A red dot in the keyboard's suggestion bar shows it is recording.")
          .font(.footnote).foregroundStyle(.secondary)
        if Settings.shared.keyboardFullAccessSeen == nil {
          Text("The keyboard records only with Full Access: without it, iOS keeps this switch from the keyboard.").font(.footnote)
        }
      }
      LabeledContent("Log", value: size == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        .accessibilityIdentifier("settings.debugLogSize")
      ShareLink(item: KeyboardLogExport(), preview: SharePreview("v2t keyboard log")) {
        Label("Export", systemImage: "square.and.arrow.up")
      }
      .disabled(size == 0)
      .accessibilityIdentifier("settings.debugLogExport")
      Button("Clear log", role: .destructive) {
        if let dir { KeyboardDebugLog.clear(in: dir) }
        size = 0
      }
      .disabled(size == 0)
      .accessibilityIdentifier("settings.debugLogClear")
      NavigationLink("Typing exercise") { TypingExerciseView() }
        .accessibilityIdentifier("settings.typingExercise")
    } header: {
      Text("Debugging")
    } footer: {
      Text("Records what you type with the v2t keyboard (keys, swipes, suggestions, corrections) to a file on this \(UIDevice.current.model), never in password, one-time-code or card fields, and turns itself off after 24 hours.")
    }
    .onAppear {
      until = Self.activeUntil
      size = dir.map(KeyboardDebugLog.size(in:)) ?? 0
    }
  }
}

/// The log's two files joined into one, oldest events first, for the share sheet.
struct KeyboardLogExport: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { _ in
      guard let dir = KeyboardLogStore.groupDirectory else { throw CocoaError(.fileNoSuchFile) }
      let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
      let url = FileManager.default.temporaryDirectory.appending(path: "v2t-keyboard-log-\(stamp).jsonl")
      try KeyboardDebugLog.merged(in: dir).write(to: url)
      return SentTransferredFile(url)
    }
  }
}
