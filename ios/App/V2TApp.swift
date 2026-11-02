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
  @State private var tryText = ""

  var body: some View {
    NavigationStack {
      List {
        Section("Set up") {
          SetupRow(number: 1, title: "Add the v2t keyboard", detail: "Settings › v2t › Keyboards › turn on v2t.", done: false) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
          SetupRow(number: 2, title: "Allow Full Access", detail: "Lets the keyboard ask v2t to dictate. Nothing you type leaves the iPhone.", done: false) {
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
          Picker("Speech language", selection: Binding(get: { Settings.shared.speechLanguage }, set: { Settings.shared.speechLanguage = $0 })) {
            Text("English").tag("en")
            Text("Español").tag("es")
            Text("Detect").tag("auto")
          }
          NavigationLink("Dictionary") { DictionaryView() }
          NavigationLink("History (\(history.items.count))") { HistoryView() }
        }
        Section("This iPhone") { RecommendationCard(rec: dictation.recommendation) }
        Section("Keyboard") { NavigationLink("Languages and typing") { KeyboardSettingsView() } }
      }
      .navigationTitle("v2t")
    }
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
        case .ready: Text("Ready. Transcription runs on this iPhone, offline.").font(.footnote).foregroundStyle(.secondary)
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

struct RecommendationCard: View {
  let rec: Recommendation
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(rec.speechName, systemImage: "waveform").font(.subheadline.weight(.semibold))
      Label(rec.cleanupName, systemImage: "sparkles").font(.subheadline)
      Text(rec.reason).font(.footnote).foregroundStyle(.secondary)
      if !rec.measured { Text("Untested on this iPhone model.").font(.footnote).foregroundStyle(.orange) }
    }
    .padding(.vertical, 4)
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
      Text("Swipe right along the bottom edge to go back to your app and keep talking. Tap the mic on the v2t keyboard when you're done.")
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

struct DictionaryView: View {
  @EnvironmentObject var dictionary: PersonalDictionary
  @State private var draft = ""
  var body: some View {
    TextEditor(text: $draft)
      .font(.body.monospaced())
      .padding(.horizontal, 8)
      .navigationTitle("Dictionary")
      .onAppear { draft = dictionary.text }
      .onDisappear { try? dictionary.save(draft) }
  }
}

struct HistoryView: View {
  @EnvironmentObject var history: History
  var body: some View {
    List {
      ForEach(history.items) { d in
        VStack(alignment: .leading, spacing: 4) {
          Text(d.text).textSelection(.enabled)
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
    .onChange(of: layout) { Settings.shared.layoutLanguage = layout }
    .onChange(of: bilingual) { Settings.shared.suggestionLanguages = bilingual ? [layout, layout == .english ? .spanish : .english] : [layout] }
    .onChange(of: warm) { Settings.shared.warmMinutes = warm }
  }
}
