import AppKit
import SQLite3
import SwiftUI

// The Voice2Text window: Models, History and Agents, and the first-run onboarding.
// It only displays what the engine's CLI reports and calls back into the menu app
// (Voice2TextMenu) for every change, so the menu and the window share one path.

/// One row of a model picker, as `v2t config --json` sends it (see v2t/models.py).
struct ModelRow: Identifiable, Equatable {
    let id: String
    let name: String
    let recommended: Bool
    let sizeGB: Double?
    let downloaded: Bool?
    let available: Bool
    let current: Bool
    let note: String
    let downloadDir: String?
    let pairs: [String]

    init(_ row: [String: Any]) {
        let label = row["label"] as? String ?? "?"
        id = row["id"] as? String ?? label
        recommended = label.hasSuffix(" (default)")
        name = recommended ? String(label.dropLast(" (default)".count)) : label
        sizeGB = row["size_gb"] as? Double
        downloaded = row["downloaded"] as? Bool
        available = row["available"] as? Bool == true
        current = row["current"] as? Bool == true
        note = row["note"] as? String ?? ""
        downloadDir = row["download_dir"] as? String
        pairs = (row["set"] as? [[String]] ?? []).flatMap { $0 }
    }

    var size: String { sizeGB.map { String(format: "%.2g GB", $0) } ?? "" }
    var pickable: Bool { available && !pairs.isEmpty }
}

/// One past dictation, read from history.sqlite.
struct HistoryEntry: Identifiable, Equatable {
    let id: Int64
    let date: Date?
    let seconds: Double?
    let raw: String
    let clean: String
}

/// `v2t agents --json`.
struct AgentsStatus: Equatable {
    struct Harness: Identifiable, Equatable {
        let id: String
        let name: String
        let present: Bool
        let instructions: String
        let skillStates: [String]
        let linePresent: Bool

        var skillsState: String {
            if skillStates.allSatisfy({ $0 == "installed" }) { return "installed" }
            if skillStates.contains("outdated") || skillStates.contains("installed") { return "outdated" }
            return "missing"
        }
    }

    let line: String
    let skills: [String]
    let harnesses: [Harness]

    init?(_ json: [String: Any]?) {
        guard let json, let rows = json["harnesses"] as? [[String: Any]] else { return nil }
        line = json["line"] as? String ?? ""
        skills = json["skills"] as? [String] ?? []
        harnesses = rows.map { row in
            Harness(
                id: row["id"] as? String ?? "?", name: row["name"] as? String ?? "?",
                present: row["present"] as? Bool == true, instructions: row["instructions"] as? String ?? "",
                skillStates: (row["skills"] as? [[String: Any]] ?? []).map { $0["state"] as? String ?? "missing" },
                linePresent: row["line_present"] as? Bool == true)
        }
    }
}

enum WindowSection: String, CaseIterable, Identifiable {
    case models, history, agents
    var id: String { rawValue }
    var title: String {
        switch self {
        case .models: "Models"
        case .history: "History"
        case .agents: "Agents"
        }
    }
    var symbol: String {
        switch self {
        case .models: "cpu"
        case .history: "clock.arrow.circlepath"
        case .agents: "terminal"
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, model, cleanup, tryIt
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .model: "Speech model"
        case .cleanup: "Cleanup"
        case .tryIt: "Try it"
        }
    }
}

/// What the window shows. The menu app keeps it current (`Voice2TextMenu.syncAppState`)
/// and sets the actions, each of which goes through the same code as the menu's rows.
final class AppState: ObservableObject {
    @Published var phase = "off"
    @Published var speech: [ModelRow] = []
    @Published var cleanup: [ModelRow] = []
    @Published var cleanupEnabled = false
    @Published var hotkey = "fn"
    @Published var microphone = false
    @Published var accessibility = false
    @Published var engineInstalled = true
    /// Bytes in the recommended model's download folder while it downloads.
    @Published var downloadedBytes: Int64?
    @Published var section = WindowSection.models
    @Published var onboarding: OnboardingStep?
    @Published var agents: AgentsStatus?
    @Published var agentsBusy = false
    /// Set when the last agents command failed, until the next one succeeds.
    @Published var agentsFailed = false

    var historyFile = URL(fileURLWithPath: "/dev/null")
    var choose: ([String]) -> Void = { _ in }
    var start: () -> Void = {}
    var requestMicrophone: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var finishOnboarding: () -> Void = {}
    /// Imports a legacy transcriptions.jsonl into history.sqlite (through `v2t history`),
    /// then calls back; calls back at once when there is nothing to import.
    var importLegacyHistory: (@escaping () -> Void) -> Void = { $0() }
    /// Runs `v2t agents <arguments> --json` in the background; nil when it failed.
    var agentsCommand: ([String], @escaping ([String: Any]?) -> Void) -> Void = { _, done in done(nil) }

    var recommendedSpeech: ModelRow? { speech.first(where: \.recommended) ?? speech.first }
    var recommendedCleanup: ModelRow? { cleanup.first(where: \.recommended) ?? cleanup.first { $0.id != "off" } }
    /// The cleanup model that runs when the switch is on: the one config.toml names, which
    /// turning cleanup off keeps (the picker marks only Off as current then).
    var chosenCleanup: ModelRow? { cleanup.first { $0.current && $0.id != "off" } ?? recommendedCleanup }

    /// Cleanup on or off, changing only `cleanup.enabled`, so a chosen engine and model stay.
    var cleanupSwitch: Binding<Bool> {
        Binding(get: { self.cleanupEnabled }, set: { self.choose(["cleanup.enabled", $0 ? "true" : "false"]) })
    }
    /// The keys `hotkey.key` takes, as the menu's Hotkey submenu lists them.
    static let hotkeys = [
        ("fn", "fn (Globe)"), ("cmd_r", "Right Command"), ("cmd_l", "Left Command"),
        ("alt_r", "Right Option"), ("alt_l", "Left Option"), ("ctrl_r", "Right Control"), ("ctrl_l", "Left Control"),
    ]

    var hotkeyName: String {
        switch hotkey {
        case "cmd_r": "Right ⌘"
        case "cmd_l": "Left ⌘"
        case "alt_r": "Right ⌥"
        case "alt_l": "Left ⌥"
        case "ctrl_r": "Right ⌃"
        case "ctrl_l": "Left ⌃"
        default: "fn"
        }
    }

    func refreshAgents() {
        runAgents([])
    }

    /// One command at a time, the buttons disabled meanwhile: a second Install still running
    /// after a Remove would put the skills back.
    func runAgents(_ arguments: [String]) {
        guard !agentsBusy else { return }
        agentsBusy = true
        agentsCommand(arguments) { [weak self] json in
            guard let self else { return }
            if let status = AgentsStatus(json) {
                self.agents = status
                self.agentsFailed = false
                self.agentsBusy = false
            } else if arguments.isEmpty {
                self.agentsFailed = true
                self.agentsBusy = false
            } else {
                // a change may have half happened: show what is on disk now, still busy until then
                self.agentsFailed = true
                self.agentsCommand([]) {
                    if let s = AgentsStatus($0) { self.agents = s }
                    self.agentsBusy = false
                }
            }
        }
    }

    /// Newest first; `search` matches the raw or the cleaned text.
    func history(search: String, limit: Int = 300) -> [HistoryEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(historyFile.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var query = "SELECT id, ts, audio_s, COALESCE(raw, ''), COALESCE(clean, '') FROM transcriptions"
            + " WHERE (COALESCE(raw, '') != '' OR COALESCE(clean, '') != '')"
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty { query += " AND (raw LIKE ?1 ESCAPE '\\' OR clean LIKE ?1 ESCAPE '\\')" }
        query += " ORDER BY id DESC LIMIT \(limit)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if !term.isEmpty {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            // the search is literal: % and _ in it match themselves, as in `v2t history TERM`
            let literal = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sqlite3_bind_text(statement, 1, "%\(literal)%", -1, transient)
        }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let seconds = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
            entries.append(HistoryEntry(id: sqlite3_column_int64(statement, 0), date: Self.parse(text(1)),
                                        seconds: seconds, raw: text(3), clean: text(4)))
        }
        return entries
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parse(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            ?? ISO8601DateFormatter().date(from: text + "Z")
    }
}

/// The window itself: an ordinary titled window hosting SwiftUI, so the app stays a
/// menu-bar (accessory) app with no Dock icon.
final class AppWindow: NSObject, NSWindowDelegate {
    let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    var isVisible: Bool { window?.isVisible == true }

    /// `activate` brings the app forward, for a click in the menu; a window opened at
    /// launch or from the command line (`--window`) opens behind whatever has the focus.
    func show(_ section: WindowSection? = nil, activate: Bool) {
        if let section { state.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if !window.isVisible {
            window.orderBack(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Voice2Text"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentView = NSHostingView(rootView: AppRoot(state: state))
        window.center()
        window.setFrameAutosaveName("Voice2Text.window")
        window.delegate = self
        return window
    }
}

// MARK: - Shared pieces

/// A state shown with a symbol and a word, never colour alone.
struct StatusLabel: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .font(.callout)
    }
}

struct ModelStatus: View {
    let row: ModelRow

    var body: some View {
        if !row.available && row.note.hasPrefix("needs voice2text") {
            StatusLabel(text: "Needs " + row.note.dropFirst("needs ".count), symbol: "puzzlepiece.extension")
        } else if !row.available {
            StatusLabel(text: row.note.isEmpty ? "Not available" : row.note.prefix(1).uppercased() + row.note.dropFirst(),
                        symbol: "exclamationmark.circle")
        } else if row.downloaded == true {
            StatusLabel(text: "Downloaded · \(row.size)", symbol: "checkmark.circle")
        } else if row.downloaded == false {
            StatusLabel(text: "\(row.size) to download", symbol: "arrow.down.circle")
        } else if !row.note.isEmpty {
            StatusLabel(text: row.note.prefix(1).uppercased() + row.note.dropFirst(), symbol: "network")
        }
    }
}

struct ModelRowView: View {
    @ObservedObject var state: AppState
    let row: ModelRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: row.current ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(row.current ? Color.accentColor : .secondary)
                .accessibilityLabel(row.current ? "In use" : "Not in use")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).fontWeight(row.current ? .semibold : .regular)
                    if row.recommended { RecommendedBadge() }
                    if row.current { Text("In use").font(.caption).foregroundStyle(.secondary) }
                }
                ModelStatus(row: row)
            }
            Spacer()
            if !row.current && row.pickable {
                Button("Use") { state.choose(row.pairs) }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.6)))
    }
}

/// Why the recommended speech model, and where the comparison lives.
struct RecommendationNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The fastest of the accurate models: 5% of words wrong on 208 real dictations, run on this Mac's Neural Engine, offline.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("How the models compare", destination: URL(string: "https://v2t.luischav.es/images/models.svg")!)
                .font(.callout)
        }
    }
}

// MARK: - Sections

struct ModelsSection: View {
    @ObservedObject var state: AppState
    @State private var showOthers = false

    var body: some View {
        Section {
            if let recommended = state.recommendedSpeech {
                ModelRowView(state: state, row: recommended)
                RecommendationNote()
            } else {
                Text(state.engineInstalled ? "Reading models…" : "v2t is not installed. Run: uv tool install --python 3.13 voice2text")
                    .foregroundStyle(.secondary)
            }
            let others = state.speech.filter { $0.id != state.recommendedSpeech?.id }
            if !others.isEmpty {
                DisclosureGroup("Other models", isExpanded: $showOthers) {
                    ForEach(others) { ModelRowView(state: state, row: $0) }
                }
            }
        } header: {
            Text("Speech")
        }
        CleanupSection(state: state)
    }
}

struct CleanupSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section {
            Toggle(isOn: state.cleanupSwitch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up text")
                    Text(state.cleanupEnabled
                         ? "A small local model adds punctuation and drops ums before pasting."
                         : "Off: you get the raw text, plus your dictionary's replacements. On, it cleans up with \(state.chosenCleanup?.name ?? "a small local model") (\(state.chosenCleanup?.size ?? ""), downloaded once).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if state.cleanupEnabled {
                ForEach(state.cleanup.filter { $0.id != "off" }) { ModelRowView(state: state, row: $0) }
            }
        } header: {
            Text("Cleanup")
        }
    }
}

struct HistorySection: View {
    @ObservedObject var state: AppState
    @State private var search = ""
    @State private var showRaw = false
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                Picker("", selection: $showRaw) {
                    Text("Cleaned").tag(false)
                    Text("Raw text").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .labelsHidden()
            }
            .padding(10)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "clock").font(.title).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "Your dictations show here." : "No dictation matches.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(entries) { HistoryRow(entry: $0, showRaw: showRaw) }
                    .listStyle(.inset)
            }
        }
        .onAppear { state.importLegacyHistory { reload() } }
        .onChange(of: search) { _ in reload() }
        // after a dictation, and after a stop (the engine finishes and saves the one in hand first)
        .onChange(of: state.phase) { phase in
            if phase == "idle" || phase == "off" { state.importLegacyHistory { reload() } }
        }
    }

    private func reload() { entries = state.history(search: search) }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let showRaw: Bool

    private var text: String {
        let preferred = showRaw ? entry.raw : entry.clean
        return preferred.isEmpty ? (showRaw ? entry.clean : entry.raw) : preferred
    }

    private var meta: String {
        var parts: [String] = []
        if let date = entry.date {
            parts.append(Calendar.current.isDateInToday(date)
                         ? date.formatted(date: .omitted, time: .shortened)
                         : date.formatted(date: .abbreviated, time: .shortened))
        }
        if let seconds = entry.seconds { parts.append(seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int(seconds / 60)) min \(Int(seconds) % 60) s") }
        let words = text.split(whereSeparator: \.isWhitespace).count
        parts.append("\(words) word\(words == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text).lineLimit(4).textSelection(.enabled)
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy")
        }
        .padding(.vertical, 4)
    }
}

struct AgentsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            Section {
                Text("Give your coding agents the v2t skills (transcribe files, grow your dictionary) and one line telling them you dictate. Nothing is written until you click.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = state.agents?.line {
                    Text(line)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
            }
            if let agents = state.agents {
                ForEach(agents.harnesses) { harness in
                    Section {
                        HarnessRows(state: state, harness: harness, skills: agents.skills)
                    } header: {
                        Text(harness.name)
                    }
                }
            } else {
                Section { Text(state.agentsBusy ? "Checking…" : "Could not check the agents: is v2t up to date?").foregroundStyle(.secondary) }
            }
            if state.agentsFailed && state.agents != nil {
                Section {
                    StatusLabel(text: "That didn't work. Check the file or folder can be written, or run v2t agents in a terminal to see why.",
                                symbol: "exclamationmark.triangle", tint: .primary)
                }
            }
        }
        .onAppear { state.refreshAgents() }
    }
}

struct HarnessRows: View {
    @ObservedObject var state: AppState
    let harness: AgentsStatus.Harness
    let skills: [String]

    var body: some View {
        if !harness.present {
            StatusLabel(text: "Not found on this Mac", symbol: "minus.circle")
        }
        HStack {
            switch harness.skillsState {
            case "installed": StatusLabel(text: "Skills installed", symbol: "checkmark.circle")
            case "outdated": StatusLabel(text: "Skills need an update", symbol: "arrow.triangle.2.circlepath")
            default: StatusLabel(text: "Skills not installed", symbol: "circle")
            }
            Spacer()
            switch harness.skillsState {
            case "installed": Button("Remove") { state.runAgents(["remove", "skills", harness.id]) }
            case "outdated": Button("Update") { state.runAgents(["install", "skills", harness.id]) }
            default: Button("Install") { state.runAgents(["install", "skills", harness.id]) }
            }
        }
        .help(skills.joined(separator: ", "))
        .disabled(state.agentsBusy || !harness.present)
        HStack {
            let file = (harness.instructions as NSString).lastPathComponent
            StatusLabel(text: harness.linePresent ? "Line in \(file)" : "Line not in \(file)",
                        symbol: harness.linePresent ? "checkmark.circle" : "circle")
            Spacer()
            Button(harness.linePresent ? "Remove line" : "Add line") {
                state.runAgents([harness.linePresent ? "remove" : "install", "line", harness.id])
            }
        }
        .help((harness.instructions as NSString).abbreviatingWithTildeInPath)
        .disabled(state.agentsBusy || !harness.present)
    }
}

/// History and the forms each in their own scroll: History is a list with its own search bar.
struct SectionContent: View {
    @ObservedObject var state: AppState
    let section: WindowSection

    var body: some View {
        switch section {
        case .history: HistorySection(state: state)
        case .models: Form { ModelsSection(state: state) }.formStyle(.grouped)
        case .agents: Form { AgentsSection(state: state) }.formStyle(.grouped)
        }
    }
}

// MARK: - Root

struct AppRoot: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if let step = state.onboarding {
                OnboardingView(state: state, step: step)
            } else {
                SidebarLook(state: state)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// Sections in a sidebar, like System Settings; the engine's state at its foot.
struct SidebarLook: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(WindowSection.allCases, selection: Binding(get: { state.section }, set: { if let s = $0 { state.section = s } })) {
                Label($0.title, systemImage: $0.symbol).tag($0)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
            StatusFooter(state: state).padding(10)
        } detail: {
            SectionContent(state: state, section: state.section)
                .navigationTitle(state.section.title)
        }
    }
}

/// The engine's state in one line: "Ready · hold fn to dictate".
struct StatusFooter: View {
    @ObservedObject var state: AppState

    var body: some View {
        switch state.phase {
        case "idle", "cancelled":
            StatusLabel(text: "Ready · hold \(state.hotkeyName) to dictate", symbol: "waveform")
        case "recording": StatusLabel(text: "Recording…", symbol: "waveform.circle")
        case "transcribing": StatusLabel(text: "Transcribing…", symbol: "ellipsis.circle")
        case "cleaning": StatusLabel(text: "Cleaning up…", symbol: "ellipsis.circle")
        case "delivering": StatusLabel(text: "Pasting…", symbol: "ellipsis.circle")
        case "starting", "permissions", "loading-stt", "loading-cleanup":
            StatusLabel(text: "Starting…", symbol: "hourglass")
        case "error", "permission-error", "no-engine", "awaiting-accessibility":
            StatusLabel(text: "Needs attention: see the menu", symbol: "exclamationmark.triangle")
        default:
            StatusLabel(text: "Off", symbol: "waveform.slash")
        }
    }
}

// MARK: - Onboarding


/// Advances on its own once a permission is granted, so nobody has to click Continue
/// after flipping a switch in System Settings.
struct OnboardingFlow {
    let state: AppState

    func next(after step: OnboardingStep) {
        guard let following = OnboardingStep(rawValue: step.rawValue + 1) else {
            state.finishOnboarding()
            return
        }
        state.onboarding = following
        // Starting asks for any permission still missing, so a skipped step waits for the menu's Start.
        if following == .model && state.microphone && state.accessibility { state.start() }
    }

    func canContinue(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: state.microphone
        case .accessibility: state.accessibility
        default: true
        }
    }
}

/// The content of each setup step.
struct StepBody: View {
    @ObservedObject var state: AppState
    let step: OnboardingStep
    @State private var tryText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .welcome:
                Text("Speak, and your words appear where you're typing. Offline, on this Mac.")
                Text("Setting up takes a minute: two permissions and one model download.")
                    .foregroundStyle(.secondary)
            case .microphone:
                Text("v2t listens only while you hold the hotkey. Audio never leaves this Mac.")
                PermissionRow(granted: state.microphone, grantedText: "Microphone allowed", missingText: "Not allowed yet")
                if !state.microphone { Button("Allow Microphone") { state.requestMicrophone() } }
            case .accessibility:
                Text("So v2t can hear the hotkey and paste into the app you're in. Turn Voice2Text on in the list, and this continues by itself.")
                    .fixedSize(horizontal: false, vertical: true)
                PermissionRow(granted: state.accessibility, grantedText: "Accessibility allowed", missingText: "Not allowed yet")
                if !state.accessibility { Button("Open Accessibility Settings") { state.requestAccessibility() } }
            case .model:
                if let model = state.recommendedSpeech {
                    HStack(spacing: 6) {
                        Text(model.name).font(.headline)
                        RecommendedBadge()
                    }
                    RecommendationNote()
                    DownloadProgress(state: state, model: model)
                } else if !state.engineInstalled {
                    Text("Install v2t first, in Terminal: uv tool install --python 3.13 voice2text")
                        .textSelection(.enabled)
                } else {
                    Text("Reading models…").foregroundStyle(.secondary)
                }
            case .cleanup:
                Toggle(isOn: state.cleanupSwitch) {
                    Text("Clean up my text")
                }
                .toggleStyle(.switch)
                Text(state.cleanupEnabled
                     ? "On: \(state.chosenCleanup?.name ?? "a small local model") (\(state.chosenCleanup?.size ?? "")) adds punctuation and drops ums. It takes a moment more per dictation."
                     : "Off: you get the raw text, plus your dictionary's replacements. Turn it on to clean up with \(state.chosenCleanup?.name ?? "a small local model") (\(state.chosenCleanup?.size ?? ""), downloaded once), now or later under Models.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .tryIt:
                HStack(spacing: 14) {
                    KeyCap(name: state.hotkeyName)
                    Picker("Dictation key", selection: Binding(get: { state.hotkey }, set: { state.choose(["hotkey.key", $0]) })) {
                        ForEach(AppState.hotkeys, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(maxWidth: 260)
                }
                Text("Hold \(state.hotkeyName), speak, and let go: the text is pasted where you're typing. Double-tap \(state.hotkeyName) to keep recording hands-free, and tap again to stop.")
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Click here, then hold \(state.hotkeyName) and speak", text: $tryText, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                StatusFooter(state: state)
            }
        }
    }
}

/// The dictation key drawn as a key, so the try-it step shows what to press.
struct KeyCap: View {
    let name: String

    var body: some View {
        Text(name == "fn" ? "fn  🌐" : name)
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .padding(.horizontal, 16)
            .frame(minWidth: 64, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.5)))
            .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 2)
            .accessibilityLabel("Dictation key: \(name)")
    }
}

struct PermissionRow: View {
    let granted: Bool
    let grantedText: String
    let missingText: String

    var body: some View {
        StatusLabel(text: granted ? grantedText : missingText, symbol: granted ? "checkmark.circle.fill" : "circle.dashed",
                    tint: granted ? .primary : .secondary)
    }
}

struct DownloadProgress: View {
    @ObservedObject var state: AppState
    let model: ModelRow

    var body: some View {
        switch state.phase {
        case "idle", "recording", "transcribing", "cleaning", "delivering", "cancelled", "loading-cleanup":
            StatusLabel(text: model.downloaded == true ? "Already on this Mac, ready" : "Downloaded and ready",
                        symbol: "checkmark.circle.fill", tint: .primary)
        case _ where model.downloaded == true:
            StatusLabel(text: "Already on this Mac, nothing to download · loading…", symbol: "checkmark.circle", tint: .primary)
        case "starting", "permissions", "loading-stt":
            if let bytes = state.downloadedBytes, let total = model.sizeGB, model.downloaded == false {
                let fraction = min(0.99, Double(bytes) / (total * 1e9))
                ProgressView(value: fraction) {
                    Text(String(format: "Downloading %.2f of %.2f GB", Double(bytes) / 1e9, total)).font(.callout)
                }
            } else {
                ProgressView {
                    Text(model.downloaded == false ? "Downloading \(model.size), once…" : "Loading…").font(.callout)
                }
            }
        default:
            StatusLabel(text: "Waiting for the permissions", symbol: "hourglass")
        }
    }
}

struct OnboardingButtons: View {
    @ObservedObject var state: AppState
    let step: OnboardingStep

    var body: some View {
        let flow = OnboardingFlow(state: state)
        HStack {
            if step != .welcome && step != .tryIt {
                Button("Skip") { flow.next(after: step) }.buttonStyle(.borderless)
            }
            Spacer()
            Button(step == .welcome ? "Get Started" : step == .tryIt ? "Done" : "Continue") { flow.next(after: step) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canContinue(step))
        }
        // A permission step moves on once granted, and at once when it already was
        .onChange(of: flow.canContinue(step)) { granted in
            if granted && (step == .microphone || step == .accessibility) { flow.next(after: step) }
        }
        .onAppear {
            if flow.canContinue(step) && (step == .microphone || step == .accessibility) { flow.next(after: step) }
        }
    }
}

private func stepHeading(_ step: OnboardingStep) -> String {
    switch step {
    case .welcome: "Voice2Text"
    case .microphone: "Allow the microphone"
    case .accessibility: "Allow Accessibility"
    case .model: "We picked the best model for this Mac"
    case .cleanup: "Clean up your text?"
    case .tryIt: "Try it"
    }
}

/// The setup: its steps listed on the left like the window's sidebar, ticked as they are done.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    Text("Set up").font(.headline)
                }
                .padding(.bottom, 6)
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Label(s.title, systemImage: s.rawValue < step.rawValue ? "checkmark.circle.fill"
                          : s == step ? "arrow.right.circle" : "circle")
                        .fontWeight(s == step ? .semibold : .regular)
                        .foregroundStyle(s.rawValue > step.rawValue ? .secondary : .primary)
                }
                Spacer()
            }
            .padding(.top, 40)
            .padding(20)
            .frame(width: 190, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(stepHeading(step)).font(.title.weight(.semibold))
                StepBody(state: state, step: step)
                Spacer()
                OnboardingButtons(state: state, step: step).id(step)  // new per step, so onAppear runs on each
            }
            .padding(.top, 40)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: .top)
    }
}
