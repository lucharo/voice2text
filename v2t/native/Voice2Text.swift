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

final class Voice2TextMenu: NSObject, NSApplicationDelegate {
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

    private var home: URL {
        let value = Bundle.main.object(forInfoDictionaryKey: "V2THome") as? String
        return URL(fileURLWithPath: value ?? NSHomeDirectory() + "/.v2t")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireAppLock() else {
            NSApp.terminate(nil)
            return
        }
        item.menu = menu
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
        guard let python = Bundle.main.object(forInfoDictionaryKey: "V2TPythonExecutable") as? String else {
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
        if let path = Bundle.main.object(forInfoDictionaryKey: "V2TConfig") as? String {
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

    private func render() {
        let microphone = microphoneGranted
        let accessibility = AXIsProcessTrusted()
        let stt = status["stt"] as? String ?? ""
        let cleanup = status["cleanup"] as? String ?? ""
        let signature = "\(phase)|\(stt)|\(cleanup)|\(engine != nil)|\(externalEngine)|\(microphone)|\(accessibility)"
        guard rendered != signature else { return }
        rendered = signature
        let presentation: (String, String) = switch phase {
        case "permissions": ("hourglass", "Checking permissions…")
        case "starting", "loading-stt": ("hourglass", "Loading transcription model…")
        case "loading-cleanup": ("hourglass", "Loading cleanup model…")
        case "idle": ("waveform", "Ready")
        case "recording": ("waveform.circle.fill", "Recording…")
        case "transcribing": ("ellipsis.circle", "Transcribing…")
        case "cleaning": ("ellipsis.circle", "Cleaning up…")
        case "stopping": ("hourglass", "Stopping…")
        case "permission-error": ("exclamationmark.triangle", "Permissions required")
        case "error": ("exclamationmark.triangle", "Could not start — open Log")
        default: ("waveform.slash", "Off")
        }
        let icon = NSImage(systemSymbolName: presentation.0, accessibilityDescription: presentation.1)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: presentation.1)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        item.button?.toolTip = presentation.1
        menu.removeAllItems()
        add(presentation.1, enabled: false)
        if !stt.isEmpty && !cleanup.isEmpty {
            add("\(stt) · \(cleanup == "off" ? "no cleanup" : "clean: \(cleanup)")", enabled: false)
        }
        menu.addItem(.separator())
        if externalEngine { add("Running from terminal", enabled: false) }
        else if phase == "permissions" || phase == "starting" { add("Starting…", enabled: false) }
        else if phase == "stopping" { add("Stopping…", enabled: false) }
        else if engine == nil { add("Start v2t", action: #selector(start)) }
        else { add("Stop v2t", action: #selector(stop)) }
        menu.addItem(.separator())
        add(permissionLabel("Microphone", microphone), action: #selector(openMicrophone))
        add(permissionLabel("Accessibility", accessibility), action: #selector(openAccessibility))
        menu.addItem(.separator())
        add("Config", action: #selector(openConfig))
        add("Transcription History", action: #selector(openHistory))
        add("Log", action: #selector(openLog))
        menu.addItem(.separator())
        add("Quit Voice2Text", action: #selector(quit))
    }

    private var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func permissionLabel(_ name: String, _ granted: Bool) -> String {
        "\(granted ? "✓" : "○") \(name) · \(granted ? "Granted" : "Click to grant")"
    }

    private func add(_ title: String, action: Selector? = nil, enabled: Bool = true) {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        row.isEnabled = enabled
        menu.addItem(row)
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
