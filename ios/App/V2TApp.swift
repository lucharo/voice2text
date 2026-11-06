import SwiftUI
import V2TKeyboardCore

@main struct V2TApp: App {
  @StateObject private var history: History
  @StateObject private var dictionary: PersonalDictionary
  @StateObject private var dictation: DictationService

  init() {
    // UI tests pick the keyboard layout through the launch environment
    if let layout = ProcessInfo.processInfo.environment["V2T_LAYOUT"], let l = KeyboardLanguage(rawValue: layout) {
      Settings.shared.layoutLanguage = l
      Settings.shared.defaults.removeObject(forKey: "learnedWords")  // each UI test starts with nothing learned
    }
    let env = ProcessInfo.processInfo.environment
    Settings.shared.previewRecording = env["V2T_PREVIEW_RECORDING"]  // never left on after a UI test
    Settings.shared.previewGlobeKey = env["V2T_PREVIEW_GLOBE"].map { $0 == "1" }
    Settings.shared.previewMicStyle = env["V2T_MIC_STYLE"]
    let h = History(), d = PersonalDictionary()
    _history = StateObject(wrappedValue: h)
    _dictionary = StateObject(wrappedValue: d)
    _dictation = StateObject(wrappedValue: DictationService(recommendation: .current, history: h, dictionary: d))
  }

  var body: some Scene {
    WindowGroup {
      HomeView()
        .environmentObject(history)
        .environmentObject(dictionary)
        .environmentObject(dictation)
        .onOpenURL { url in
          if url.scheme == "v2t", url.host == "dictate" { dictation.handleKeyboardLaunch() }
        }
        .task { await dictation.prepareModel() }
    }
  }
}

struct HomeView: View {
  @EnvironmentObject var dictation: DictationService
  @EnvironmentObject var history: History
  @Environment(\.scenePhase) private var scenePhase
  @State private var tryText = ""
  @State private var keyboardSeen = Settings.shared.keyboardFullAccessSeen

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
            .accessibilityIdentifier("v2t.try")
        }
        Section("Dictation") {
          WarmRow()
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
        Section("Keyboard") { NavigationLink("Languages and typing") { KeyboardSettingsView() } }
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
    }
    .onChange(of: tryText) { keyboardSeen = Settings.shared.keyboardFullAccessSeen }
    .fullScreenCover(isPresented: $dictation.cameFromKeyboard) { KeyboardHandoffView() }
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
    HStack(alignment: .top, spacing: 12) {
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
        case .notDownloaded: Button("Download") { Task { await dictation.prepareModel() } }
        }
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
    guard available else { return "Unavailable: Apple Intelligence is off or not ready on this \(dictation.recommendation.deviceName), so you get the words as heard, plus your dictionary's replacements." }
    return cleanup
      ? "On: fixes punctuation and drops fillers on the \(dictation.recommendation.deviceName), keeping your words and dictionary spellings."
      : "Off: you get the words as heard, plus your dictionary's replacements."
  }
}

struct RecommendationCard: View {
  let rec: Recommendation
  @AppStorage("cleanupEnabled", store: Settings.shared.defaults) private var cleanup = true
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(rec.speechName, systemImage: "waveform").font(.subheadline.weight(.semibold))
      Label(rec.cleanup == .appleIntelligence && !cleanup ? "Cleanup: off (turned off above)" : rec.cleanupName, systemImage: "sparkles").font(.subheadline)
      Text(rec.reason).font(.footnote).foregroundStyle(.secondary)
      if !rec.measured { Text("Untested on this \(rec.deviceName) model.").font(.footnote).foregroundStyle(.orange) }
    }
    .padding(.vertical, 4)
  }
}

/// The input the session records from, by the name iOS gives it, so a headset or car taking over is obvious.
struct MicrophoneLabel: View {
  let mic: Microphone
  var body: some View {
    Label("Recording from \(mic.name)", systemImage: mic.symbol)
      .font(.footnote).foregroundStyle(.secondary)
      .accessibilityIdentifier("v2t.microphone")
  }
}

/// Shown when the keyboard's mic opened v2t: recording has started; the user goes back to keep talking.
struct KeyboardHandoffView: View {
  @EnvironmentObject var dictation: DictationService
  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: dictation.state == .listening ? "waveform" : "mic.fill")
        .font(.system(size: 64)).foregroundStyle(.red).symbolEffect(.variableColor, isActive: dictation.state == .listening)
      Text(dictation.state == .listening ? "Listening" : "Mic is ready").font(.largeTitle.bold())
      if let mic = dictation.microphone { MicrophoneLabel(mic: mic) }
      Text("Go back to your app and keep talking: tap ◀ at the top left, or swipe right along the bottom edge. Tap the mic on the v2t keyboard when you're done.")
        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
      Image(systemName: "arrow.right").font(.title).foregroundStyle(.secondary)
      Spacer()
      Button(dictation.state == .listening ? "Stop and stay here" : "Close") {
        if dictation.state == .listening { dictation.stop() }
        dictation.cameFromKeyboard = false
      }
      .padding(.bottom, 32)
    }
  }
}

/// Words to spell exactly, and replacements, as two lists with an add row each. Same file and format as the
/// Mac app; "Edit as text" opens the file itself.
struct DictionaryView: View {
  @EnvironmentObject var dictionary: PersonalDictionary
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
    }
    .navigationTitle("Dictionary")
    .onAppear { dictionary.reload() }
    .alert("Couldn't add that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(error ?? "") }
  }

  func addTerm() {
    do { try dictionary.addTerm(term); term = "" } catch { self.error = error.localizedDescription }
  }

  func addReplacement() {
    do { try dictionary.addReplacement(heard: heard, written: written); heard = ""; written = "" } catch { self.error = error.localizedDescription }
  }

  func remove(_ offsets: IndexSet, from items: [PersonalDictionary.Item]) {
    for i in offsets { try? dictionary.remove(items[i].line) }
  }
}

/// The dictionary file as text, for pasting a list from the Mac app.
struct DictionaryTextView: View {
  @EnvironmentObject var dictionary: PersonalDictionary
  @State private var draft = ""
  @State private var snapshot = ""
  var body: some View {
    TextEditor(text: $draft)
      .font(.body.monospaced())
      .padding(.horizontal, 8)
      .navigationTitle("Dictionary file")
      .onAppear { dictionary.reload(); draft = dictionary.text; snapshot = draft }
      .onDisappear { try? dictionary.saveEdit(draft, from: snapshot) }
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
          Text(d.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .swipeActions { Button("Delete", role: .destructive) { try? history.delete(d.id) } }
      }
    }
    .overlay { if history.items.isEmpty { Text("No dictations yet").foregroundStyle(.secondary) } }
    .navigationTitle("History")
  }
}

struct KeyboardSettingsView: View {
  @EnvironmentObject var dictation: DictationService
  @State private var layout = Settings.shared.layoutLanguage
  @State private var bilingual = Settings.shared.suggestionLanguages.count > 1
  @State private var warm = Settings.shared.warmMinutes
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
