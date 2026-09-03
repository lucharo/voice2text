import AppKit
import ApplicationServices
import AVFoundation

@main
struct Voice2TextApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = Voice2TextMenu()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class Voice2TextMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var engine: Process?
    private var timer: Timer?
    private var phase = "off"
    private var status: [String: Any] = [:]
    private var externalEngine = false
    private var lockFD: Int32 = -1
    private var logHandle: FileHandle?
    private var rendered = ""
    private var terminationPending = false
    private var lastTranscription: String?

    // Info.plist bakes the installing user's paths. A bundle built and signed on
    // another Mac (the only way to get a non-ad-hoc signature onto a managed
    // machine with no signing identity) carries that other user's paths, so
    // each one falls back to this user's standard locations when it is absent.
    private var home: URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: "V2THome") as? String,
           FileManager.default.fileExists(atPath: (value as NSString).deletingLastPathComponent) {
            return URL(fileURLWithPath: value)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.v2t")
    }

    /// The Python that runs the engine: the baked interpreter, else this user's
    /// `uv tool` install of voice2text, else nil (rendered as an error).
    private var pythonExecutable: String? {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: "V2TPythonExecutable") as? String,
            NSHomeDirectory() + "/.local/share/uv/tools/voice2text/bin/python",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireAppLock() else {
            NSApp.terminate(nil)
            return
        }
        item.menu = menu
        menu.delegate = self
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if CommandLine.arguments.contains("--start") {
            start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        engine?.terminate()
        logHandle?.closeFile()
        logHandle = nil
        if lockFD >= 0 { close(lockFD) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine else { return .terminateNow }
        terminationPending = true
        phase = "stopping"
        render()
        engine.terminate()
        return .terminateLater
    }

    private func acquireAppLock() -> Bool {
        let run = home.appendingPathComponent("run")
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        chmod(home.path, 0o700)
        chmod(run.path, 0o700)
        lockFD = open(run.appendingPathComponent("menubar.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { fchmod(lockFD, 0o600) }
        return lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    @objc private func start() {
        guard engine == nil && !externalEngine && phase != "permissions" && phase != "starting" else { return }
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.removeItem(at: home.appendingPathComponent("run/last-error"))
        phase = "permissions"
        render()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            requestSystemPermissions()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.requestSystemPermissions() }
                    else { self?.phase = "permission-error"; self?.render() }
                }
            }
        default:
            phase = "permission-error"
            render()
        }
    }

    private func requestSystemPermissions() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(prompt)
        guard accessibility else {
            phase = "permission-error"
            render()
            return
        }
        launchEngine()
    }

    private func launchEngine() {
        guard let python = pythonExecutable else {
            phase = "error"
            render()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "v2t"]
        var environment = ProcessInfo.processInfo.environment
        environment["V2T_HOME"] = home.path
        environment["V2T_LAUNCH_CONTEXT"] = "menubar"
        let toolBin = URL(fileURLWithPath: python).deletingLastPathComponent().path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(toolBin):/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
        if let path = Bundle.main.object(forInfoDictionaryKey: "V2TConfig") as? String,
           FileManager.default.fileExists(atPath: path) {
            environment["V2T_CONFIG"] = path
        }
        process.environment = environment
        let log = home.appendingPathComponent("run/v2t.log")
        if let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 {
            let previous = log.deletingPathExtension().appendingPathExtension("log.1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: log, to: previous)
        }
        let logFD = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if logFD >= 0 {
            fchmod(logFD, 0o600)
            let handle = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            logHandle = handle
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let shouldQuit = self.terminationPending
                self.engine = nil
                self.logHandle?.closeFile()
                self.logHandle = nil
                self.phase = "off"
                if shouldQuit {
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    self.refresh()
                }
            }
        }
        do {
            phase = "starting"
            render()
            engine = process
            try process.run()
        } catch {
            engine = nil
            phase = "error"
            render()
        }
    }

    @objc private func stop() {
        engine?.terminate()
        phase = "stopping"
        render()
    }

    private func refresh() {
        let url = home.appendingPathComponent("run/status.json")
        var live = false
        if let data = try? Data(contentsOf: url),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let pid = value["pid"] as? Int, engineOwnsLock(pid) {
                live = true
                status = value
                externalEngine = engine == nil
                if phase != "stopping" {
                    phase = value["state"] as? String ?? phase
                }
            }
        }
        if !live && engine == nil && phase != "permission-error" && phase != "error" {
            phase = "off"
            status = [:]
            externalEngine = false
            try? FileManager.default.removeItem(at: url)
        }
        if engine == nil, let message = try? String(contentsOf: home.appendingPathComponent("run/last-error"), encoding: .utf8), !message.isEmpty {
            phase = "error"
        }
        render()
    }

    private func engineOwnsLock(_ pid: Int) -> Bool {
        let path = home.appendingPathComponent("run/v2t.lock").path
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        let owner = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return owner == String(pid)
    }

    // The menu is rebuilt on every state change and every open. Layout, top to
    // bottom: state (bold, with its symbol) and the models under it in small
    // grey type; start/stop; the last transcription with a copy action; the two
    // permission rows with coloured status dots; links; quit.
    private func render() {
        let microphone = microphoneGranted
        let accessibility = AXIsProcessTrusted()
        let stt = status["stt"] as? String ?? ""
        let cleanup = status["cleanup"] as? String ?? ""
        let signature = "\(phase)|\(stt)|\(cleanup)|\(engine != nil)|\(externalEngine)|\(microphone)|\(accessibility)|\(lastTranscription ?? "")"
        guard rendered != signature else { return }
        rendered = signature
        let presentation: (String, String, NSColor?) = switch phase {
        case "permissions": ("hourglass", "Checking permissions…", nil)
        case "starting", "loading-stt": ("hourglass", "Loading transcription model…", nil)
        case "loading-cleanup": ("hourglass", "Loading cleanup model…", nil)
        case "idle": ("waveform", "Ready", nil)
        case "recording": ("waveform.circle.fill", "Recording…", .systemRed)
        case "transcribing": ("ellipsis.circle", "Transcribing…", nil)
        case "cleaning": ("ellipsis.circle", "Cleaning up…", nil)
        case "stopping": ("hourglass", "Stopping…", nil)
        case "permission-error": ("exclamationmark.triangle", "Permissions required", .systemOrange)
        case "error": ("exclamationmark.triangle", "Could not start — open Log", .systemOrange)
        default: ("waveform.slash", "Off", nil)
        }
        let icon = NSImage(systemSymbolName: presentation.0, accessibilityDescription: presentation.1)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: presentation.1)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        item.button?.toolTip = presentation.1
        item.button?.contentTintColor = presentation.2
        menu.removeAllItems()

        let state = add(presentation.1, image: symbol(presentation.0, color: presentation.2), enabled: false)
        state.attributedTitle = NSAttributedString(
            string: presentation.1,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        if !stt.isEmpty && !cleanup.isEmpty {
            let models = "\(stt) · \(cleanup == "off" ? "no cleanup" : "clean: \(cleanup)")"
            add(models, enabled: false).attributedTitle = secondary(models)
        }
        menu.addItem(.separator())

        if externalEngine { add("Running from terminal", image: symbol("terminal"), enabled: false) }
        else if phase == "permissions" || phase == "starting" { add("Starting…", image: symbol("hourglass"), enabled: false) }
        else if phase == "stopping" { add("Stopping…", image: symbol("hourglass"), enabled: false) }
        else if engine == nil { add("Start v2t", action: #selector(start), image: symbol("play.fill"), key: "s") }
        else { add("Stop v2t", action: #selector(stop), image: symbol("stop.fill"), key: "s") }
        menu.addItem(.separator())

        if let last = lastTranscription {
            add("Last transcription", enabled: false).attributedTitle = secondary("Last transcription")
            let preview = add(excerpt(last), enabled: false)
            preview.attributedTitle = NSAttributedString(string: excerpt(last), attributes: [.font: NSFont.menuFont(ofSize: 12)])
            preview.toolTip = last
            add("Copy Last Transcription", action: #selector(copyLast), image: symbol("doc.on.doc"), key: "c")
            menu.addItem(.separator())
        }

        add(microphone ? "Microphone · Granted" : "Microphone · Click to grant",
            action: #selector(openMicrophone), image: statusDot(microphone))
        add(accessibility ? "Accessibility · Granted" : "Accessibility · Click to grant",
            action: #selector(openAccessibility), image: statusDot(accessibility))
        menu.addItem(.separator())

        add("Config Folder", action: #selector(openConfig), image: symbol("gearshape"))
        add("Transcription History", action: #selector(openHistory), image: symbol("clock.arrow.circlepath"))
        add("Log", action: #selector(openLog), image: symbol("doc.text"))
        menu.addItem(.separator())
        add("Quit Voice2Text", action: #selector(quit), key: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        loadLastTranscription()
        rendered = ""
        render()
    }

    private var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, image: NSImage? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        row.image = image
        row.isEnabled = enabled
        menu.addItem(row)
        return row
    }

    private func secondary(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let color { configuration = configuration.applying(.init(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        image?.isTemplate = color == nil
        return image
    }

    private func statusDot(_ granted: Bool) -> NSImage? {
        symbol(granted ? "checkmark.circle.fill" : "circle", color: granted ? .systemGreen : .systemOrange)
    }

    private func excerpt(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The `clean` text of the newest history record, read from the file's tail
    /// so a long history stays cheap. Bytes are split on newlines before decoding
    /// so a window boundary inside a multi-byte character cannot break the read.
    private func loadLastTranscription() {
        let url = home.appendingPathComponent("history/transcriptions.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { lastTranscription = nil; return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let line = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).last,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let clean = record["clean"] as? String, !clean.isEmpty
        else { lastTranscription = nil; return }
        lastTranscription = clean
    }

    @objc private func copyLast() {
        guard let last = lastTranscription else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(last, forType: .string)
    }

    private func openPane(_ pane: String) {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        if let url = URL(string: base + pane) { NSWorkspace.shared.open(url) }
    }

    @objc private func openMicrophone() {
        NSApp.activate(ignoringOtherApps: true)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.rendered = ""; self?.render() }
            }
        } else {
            openPane("Privacy_Microphone")
        }
    }

    @objc private func openAccessibility() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        rendered = ""
        render()
    }

    @objc private func openConfig() { NSWorkspace.shared.open(home) }
    @objc private func openHistory() { NSWorkspace.shared.open(home.appendingPathComponent("history")) }
    @objc private func openLog() { NSWorkspace.shared.open(home.appendingPathComponent("run/v2t.log")) }
    @objc private func quit() { NSApp.terminate(nil) }
}
