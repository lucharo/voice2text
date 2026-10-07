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
    private let pill = Pill()
    private var liveSource: DispatchSourceRead?
    private var liveSocketID: (device: dev_t, inode: ino_t)?
    private var menuIsOpen = false

    // Info.plist bakes the installing user's paths. A bundle built and signed on
    // another Mac (the only way to get a non-ad-hoc signature onto a managed
    // machine with no signing identity) carries that other user's paths, so
    // each one falls back to this user's standard locations when it is absent.
    private var home: URL {
        if let value = ProcessInfo.processInfo.environment["V2T_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "V2THome") as? String,
           FileManager.default.fileExists(atPath: (value as NSString).deletingLastPathComponent) {
            return URL(fileURLWithPath: value)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.v2t")
    }

    /// The Python that runs the engine: the baked interpreter, else this user's
    /// `uv tool` install of voice2text, else nil (rendered as "not installed").
    private var pythonExecutable: String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: "V2TPythonExecutable") as? String,
            environment["UV_TOOL_DIR"].map { $0 + "/voice2text/bin/python" },
            environment["XDG_DATA_HOME"].map { $0 + "/uv/tools/voice2text/bin/python" },
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
        pill.onUndo = { [weak self] in self?.undoDictation() }
        menu.delegate = self
        listenForLiveEvents()
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Opening the app starts dictation once both grants exist, so nobody
        // has to press Start after a login, an upgrade or a relaunch. Without
        // them, Start stays a deliberate click that leads to the prompts.
        refresh()
        let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
        if CommandLine.arguments.contains("--start") || granted {
            start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let liveSource {  // a second launch that lost the lock never bound it
            liveSource.cancel()
            // A copy that handed over to /Applications quits after the new copy
            // has bound its own socket here: unlink only the one this copy made.
            let path = home.appendingPathComponent("run/live.sock").path
            var info = stat()
            if let id = liveSocketID, stat(path, &info) == 0, info.st_dev == id.device, info.st_ino == id.inode {
                unlink(path)
            }
        }
        if let engine, engine.isRunning {  // normally gone already: see applicationShouldTerminate
            engine.terminate()
            let deadline = Date().addingTimeInterval(Self.teardownGrace)
            while engine.isRunning && Date() < deadline { usleep(50_000) }
            if engine.isRunning { kill(engine.processIdentifier, SIGKILL) }
        }
        logHandle?.closeFile()
        logHandle = nil
        if lockFD >= 0 { close(lockFD) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine else { return .terminateNow }
        terminationPending = true
        phase = "stopping"
        render()
        terminateEngine(engine)
        return .terminateLater
    }

    /// How long the engine may still run after it has cleared its status file, the
    /// last step of its shutdown, before SIGKILL. Exiting from there takes
    /// milliseconds; only a hung teardown (a CoreAudio deadlock, PortAudio#1174,
    /// holding the microphone) is still running after this.
    static let teardownGrace: TimeInterval = 5

    /// SIGTERM, then SIGKILL only if the engine finished its work and cleared its
    /// status but is still running `teardownGrace` later. Work in hand, however long
    /// (an Ollama cleanup may take a minute), is never cut short.
    private func terminateEngine(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        let status = home.appendingPathComponent("run/status.json").path
        var clearedAt: Date?
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard process.isRunning else { timer.invalidate(); return }
            guard !FileManager.default.fileExists(atPath: status) else { clearedAt = nil; return }
            let since = clearedAt ?? Date()
            clearedAt = since
            if Date().timeIntervalSince(since) >= Self.teardownGrace {
                kill(pid, SIGKILL)
                timer.invalidate()
            }
        }
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
        try? FileManager.default.removeItem(at: home.appendingPathComponent("run/last-error"))
        phase = "permissions"
        render()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            requestSystemPermissions()
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)  // only a prompt needs the focus
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

    // An ungranted Accessibility prompt sends the user to System Settings; the
    // one-second refresh starts the engine as soon as the switch is on, so
    // nobody has to come back and press Start a second time.
    private func requestSystemPermissions() {
        if !AXIsProcessTrusted() { NSApp.activate(ignoringOtherApps: true) }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            phase = "awaiting-accessibility"
            render()
            return
        }
        launchEngine()
    }

    @objc private func cancelStart() {
        phase = "off"
        render()
    }

    /// Forgets this app's Microphone and Accessibility decisions and asks again.
    /// A grant made for a differently signed build with the same bundle ID (an
    /// older local build, a copy elsewhere) still shows as on in System Settings
    /// but no longer matches this signature, and flipping the switch does not
    /// always rewrite it; a reset is the one reliable way out.
    @objc private func resetPermissions() {
        for service in ["Microphone", "Accessibility"] {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.lucharo.voice2text"]
            do {
                try reset.run()
                reset.waitUntilExit()
            } catch {}
        }
        phase = "off"
        start()
    }

    // Voice2Text bundles in the two install locations other than this one. They
    // share one bundle ID, and macOS keeps a single Microphone and Accessibility
    // grant per ID pinned to one signature, so whichever copy asked last revokes
    // the other's. /Applications (the Homebrew cask) is the copy to keep.
    private static let systemCopy = URL(fileURLWithPath: "/Applications/Voice2Text.app")
    private static let userCopy = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Voice2Text.app")

    private var otherCopy: URL? {
        let own = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return [Self.systemCopy, Self.userCopy].first {
            $0.resolvingSymlinksInPath().standardizedFileURL != own
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }
    }

    private var runningFromSystemCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            == Self.systemCopy.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether the menu can settle the clash: from /Applications by binning the
    /// other copy, or from elsewhere by handing over to /Applications. A build
    /// folder facing only a ~/Applications copy just shows the warning.
    private var canResolveOtherCopy: Bool {
        runningFromSystemCopy || otherCopy == Self.systemCopy
    }

    /// From /Applications: bin the stray copy. From anywhere else: open the
    /// /Applications copy and, once it has launched, bin this one if it is the
    /// old ~/Applications install (a build folder is left alone) and quit.
    @objc private func resolveOtherCopy() {
        guard let other = otherCopy, engine == nil, canResolveOtherCopy else { return }
        if runningFromSystemCopy {
            NSWorkspace.shared.recycle([other]) { [weak self] _, error in
                DispatchQueue.main.async {
                    if error == nil { self?.repointLoginAgent(from: other, to: Self.systemCopy) }
                    self?.rendered = ""
                    self?.render()
                }
            }
            return
        }
        let own = Bundle.main.bundleURL
        let ownIsUserCopy = own.resolvingSymlinksInPath().standardizedFileURL
            == Self.userCopy.resolvingSymlinksInPath().standardizedFileURL
        // Release the single-instance lock so the /Applications copy can take it;
        // take it back if that copy does not launch.
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
        NSWorkspace.shared.openApplication(at: Self.systemCopy, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else {
                    _ = self.acquireAppLock()
                    self.rendered = ""
                    self.render()
                    return
                }
                guard ownIsUserCopy else { NSApp.terminate(nil); return }
                self.repointLoginAgent(from: own, to: Self.systemCopy)
                // Quit only once the move is done; quitting first abandons it.
                NSWorkspace.shared.recycle([own]) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// `v2t service install` bakes the bundle path into the login agent; when that
    /// bundle has just gone to the Bin, point the agent at the copy that stays.
    private func repointLoginAgent(from binned: URL, to kept: URL) {
        let agent = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/"
            + (Bundle.main.bundleIdentifier ?? "com.lucharo.voice2text") + ".plist")
        guard let data = try? Data(contentsOf: agent),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var arguments = plist["ProgramArguments"] as? [String],
              let program = arguments.first, program.hasPrefix(binned.path + "/")
        else { return }
        arguments[0] = kept.appendingPathComponent("Contents/MacOS/Voice2Text").path
        plist["ProgramArguments"] = arguments
        if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? updated.write(to: agent, options: .atomic)
        }
    }

    private func launchEngine() {
        guard engine == nil else { return }
        guard let python = pythonExecutable else {
            phase = "no-engine"
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
        if let engine { terminateEngine(engine) }
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
        if phase == "awaiting-accessibility" && AXIsProcessTrusted() {
            launchEngine()
            return
        }
        if !live && engine == nil && !["permissions", "permission-error", "awaiting-accessibility", "error", "no-engine"].contains(phase) {
            phase = "off"
            status = [:]
            externalEngine = false
            try? FileManager.default.removeItem(at: url)
        }
        if engine == nil, let message = try? String(contentsOf: home.appendingPathComponent("run/last-error"), encoding: .utf8), !message.isEmpty {
            phase = "error"
        }
        pill.update(phase: phase, partial: status["partial"] as? String ?? "",
                    liveTranscript: status["live_transcript"] as? Bool ?? false)
        render()
    }

    /// Binds run/live.sock, where the engine sends each status change as it
    /// happens and, while recording, the input level for the pill's waveform.
    /// The one-second status poll stays the fallback, and the only source for
    /// an engine that predates the socket (its pill shows no waveform).
    private func listenForLiveEvents() {
        let path = home.appendingPathComponent("run/live.sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }  // NUL-terminated
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        unlink(path)  // left behind by a previous run
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return }
        chmod(path, 0o600)
        var info = stat()
        if stat(path, &info) == 0 { liveSocketID = (info.st_dev, info.st_ino) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readLiveEvents(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        liveSource = source
    }

    private func readLiveEvents(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var statusChanged = false
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            guard let event = try? JSONSerialization.jsonObject(with: Data(buffer[..<count])) as? [String: Any]
            else { continue }
            if let level = event["level"] as? Double {
                pill.push(level: level)
            } else {
                statusChanged = true
            }
        }
        // The engine writes status.json just before it sends the event, so a
        // re-read goes through the same ownership checks as the poll.
        if statusChanged { refresh() }
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
        // While recording with the streaming recogniser, the engine reports how
        // much it has heard so far: a word count and the tail of the text.
        let heardWords = phase == "recording" ? status["words"] as? Int ?? 0 : 0
        let heardTail = phase == "recording" ? status["partial"] as? String ?? "" : ""
        let other = otherCopy
        let signature = "\(pill.style.rawValue)|\(other?.path ?? "")|\(phase)|\(stt)|\(cleanup)|\(engine != nil)|\(externalEngine)|\(microphone)|\(accessibility)|\(lastTranscription ?? "")|\(heardWords)|\(heardTail)"
        guard rendered != signature else { return }
        rendered = signature
        let presentation: (String, String, NSColor?) = switch phase {
        case "permissions": ("hourglass", "Checking permissions…", nil)
        case "starting", "loading-stt": ("hourglass", "Loading transcription model…", nil)
        case "loading-cleanup": ("hourglass", "Loading cleanup model…", nil)
        case "idle": ("waveform", "Ready", nil)
        case "cancelled": ("arrow.uturn.backward", "Dictation cancelled · Undo available", nil)
        case "recording": ("waveform.circle.fill", heardWords > 0 ? "Recording… \(heardWords) words" : "Recording…", .systemRed)
        case "transcribing": ("ellipsis.circle", "Transcribing…", nil)
        case "cleaning": ("ellipsis.circle", "Cleaning up…", nil)
        case "delivering": ("ellipsis.circle", "Pasting…", nil)
        case "stopping": ("hourglass", "Stopping…", nil)
        case "permission-error": ("exclamationmark.triangle", "Permissions required", .systemOrange)
        case "awaiting-accessibility": ("hand.raised", "Turn on Voice2Text under Accessibility", .systemOrange)
        case "error": ("exclamationmark.triangle", "Could not start — open Log", .systemOrange)
        case "no-engine": ("exclamationmark.triangle", "v2t is not installed", .systemOrange)
        default: ("waveform.slash", "Off", nil)
        }
        let icon = NSImage(systemSymbolName: presentation.0, accessibilityDescription: presentation.1)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: presentation.1)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        item.button?.toolTip = heardTail.isEmpty ? presentation.1 : "\(presentation.1)\n…\(heardTail)"
        item.button?.contentTintColor = presentation.2
        // Streamed partials arrive while the menu may be open; rebuilding it then
        // would close a submenu under the pointer. Opening rebuilds it fresh.
        guard !menuIsOpen else { return }
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
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            add("Version \(version)", enabled: false).attributedTitle = secondary("Version \(version)")
        }
        if phase == "no-engine" {
            // A prebuilt shell (brew cask) with no engine to run: name the one command.
            let hint = "Run: uv tool install voice2text"
            add(hint, enabled: false).attributedTitle = secondary(hint)
        }
        if let other {
            let folder = (other.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            let warning = add("Another copy in \(folder)", image: symbol("exclamationmark.triangle", color: .systemOrange), enabled: false)
            warning.toolTip = "Both copies share one identity, so each takes the other's Microphone and Accessibility permissions."
            if engine == nil && canResolveOtherCopy {
                add(runningFromSystemCopy ? "Move Other Copy to Bin" : "Switch to /Applications Copy",
                    action: #selector(resolveOtherCopy), image: symbol(runningFromSystemCopy ? "trash" : "arrow.right.circle"))
            }
        }
        menu.addItem(.separator())

        if phase == "cancelled" {
            add("Undo Cancel · Resume Dictation", action: #selector(undoDictation), image: symbol("arrow.uturn.backward"))
        }
        if externalEngine { add("Running from terminal", image: symbol("terminal"), enabled: false) }
        else if phase == "permissions" || phase == "starting" { add("Starting…", image: symbol("hourglass"), enabled: false) }
        else if phase == "stopping" { add("Stopping…", image: symbol("hourglass"), enabled: false) }
        else if phase == "awaiting-accessibility" { add("Cancel Start", action: #selector(cancelStart), image: symbol("xmark")) }
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
        if ["permission-error", "awaiting-accessibility"].contains(phase) {
            add("Reset Permissions", action: #selector(resetPermissions), image: symbol("arrow.counterclockwise"))
        }
        menu.addItem(.separator())

        let pillStyles = NSMenu()
        for style in PillStyle.allCases {
            let row = NSMenuItem(title: style.title, action: #selector(choosePill(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = style.rawValue
            row.state = style == pill.style ? .on : .off
            pillStyles.addItem(row)
        }
        add("Pill", image: symbol("capsule")).submenu = pillStyles
        add("Config Folder", action: #selector(openConfig), image: symbol("gearshape"))
        add("Transcription History", action: #selector(openHistory), image: symbol("clock.arrow.circlepath"))
        add("Dictionary", action: #selector(openDictionary), image: symbol("character.book.closed"))
        add("Log", action: #selector(openLog), image: symbol("doc.text"))
        add("Send Feedback…", action: #selector(openFeedback), image: symbol("bubble.left"))
        menu.addItem(.separator())
        add("Quit Voice2Text", action: #selector(quit), key: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        loadLastTranscription()
        rendered = ""
        render()
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
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

    @objc private func choosePill(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = PillStyle(rawValue: raw) else { return }
        pill.style = style
        rendered = ""
        refresh()  // a dictation in progress reappears in the new style at once
    }

    @objc private func undoDictation() {
        guard phase == "cancelled", let pid = status["pid"] as? Int, engineOwnsLock(pid) else { return }
        kill(pid_t(pid), SIGUSR1)
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
    @objc private func openDictionary() {
        let url = home.appendingPathComponent("dictionary.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(url)
    }
    @objc private func openLog() { NSWorkspace.shared.open(home.appendingPathComponent("run/v2t.log")) }
    @objc private func openFeedback() {
        if let url = URL(string: "https://github.com/lucharo/voice2text/issues/new") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Near the text cursor is the default: a speech bubble beside the focused text
/// box, pointing at the caret. A tall pane with no caret (a Ghostty split) gets
/// the pill at its bottom instead.
enum PillStyle: String, CaseIterable {
    case cursorBubble = "caret", compactBottom = "bottom", off

    var title: String {
        switch self {
        case .cursorBubble: "Near text cursor (default)"
        case .compactBottom: "Bottom of screen"
        case .off: "Off"
        }
    }
}

/// Floats the pill over every app while the engine records, transcribes or
/// cleans up. The panel never becomes key and ignores the mouse, so focus,
/// and with it the paste, stays in the app the user is typing in.
final class Pill: NSObject {
    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let view = PillView()
    private var ticker: Timer?
    private var visible = false
    /// What the focused app reports: read when the recording starts, then again
    /// every `followInterval` while the pill shows, so it follows the caret.
    struct Focus: Equatable {
        var caret: NSRect?
        var box: NSRect?  // the focused element's frame
        var atStart = false  // nothing but line breaks before the caret: an empty field
    }
    private var focus = Focus()
    /// Twice a second: a moved caret or a click into another field brings the
    /// bubble along within half a second, for two accessibility reads a second.
    private static let followInterval: TimeInterval = 0.5
    private var follower: Timer?
    private var following = false  // a read in flight; a hung app skips polls, never stacks them
    private var followGeneration = 0  // bumped on hide and on a new recording: stale reads are dropped
    private let followQueue = DispatchQueue(label: "voice2text.pill.follow")
    private var target: NSRect?  // the caret the bubble's tail points at, real or estimated
    private var pane: NSRect?
    private var screen: NSScreen?
    var onUndo: (() -> Void)?
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    var style: PillStyle {
        get { PillStyle(rawValue: UserDefaults.standard.string(forKey: "pillPlacement") ?? "") ?? .cursorBubble }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pillPlacement"); hide() }
    }

    override init() {
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        // Drawn as a light chip: an inline bezel reads as disabled in a panel
        // that is never key.
        undoButton.isBordered = false
        undoButton.wantsLayer = true
        undoButton.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        undoButton.layer?.cornerRadius = 11
        undoButton.attributedTitle = NSAttributedString(string: "Undo  ⌘Z", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        undoButton.refusesFirstResponder = true
        undoButton.focusRingType = .none
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.isHidden = true
        view.addSubview(undoButton)
    }

    @objc private func undo() { onUndo?() }

    /// Keep the recording waveform when placement or transcript visibility changes.
    /// Words show only with the experimental `live_transcript` config key on.
    func update(phase: String, partial: String, liveTranscript: Bool) {
        if phase == "recording" && view.phase != "recording" {
            followGeneration += 1
            following = false
            focus = Self.focused()
            view.begin()
            hide()  // Undo reanchors and restores the selected style's full size.
        }
        // The engine says "delivering" just before it pastes: the bubble stops
        // following and fades out as the paste lands, still showing the cleanup.
        if phase != "delivering" { view.phase = phase }
        view.partial = liveTranscript && phase == "recording" ? partial : ""
        undoButton.isHidden = phase != "cancelled"
        panel.ignoresMouseEvents = phase != "cancelled"
        guard style != .off, ["recording", "transcribing", "cleaning", "cancelled"].contains(phase) else {
            hide()
            return
        }
        if !visible { show() }
        else { position() }
        view.needsDisplay = true
    }

    func push(level: Double) {
        if visible { view.push(level) }
    }

    /// A speech bubble up and to the right of the caret, its tail curling down-left
    /// at 45 degrees to just above it, so neither the caret nor the text beside it
    /// is covered (placed on a design surface, 2026-10-06). Without room above, it
    /// sits down and to the right instead. An empty field reports no caret, so one
    /// is assumed at its start; a box taller than 40% of the screen with no caret
    /// is a document or terminal pane, and the pill sits at its bottom centre.
    private func show() {
        guard place() else { return }
        position()
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        visible = true
        // Half the original 20 Hz history speed, with two-sample smoothing.
        let ticker = Timer(timeInterval: 2.0 / 20, repeats: true) { [weak self] _ in self?.view.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        let follower = Timer(timeInterval: Self.followInterval, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(follower, forMode: .common)
        self.follower = follower
    }

    /// Re-read the focus off the main thread (a hung app would block it for an AX
    /// timeout) and move the bubble when the caret or the field changed. The
    /// Undo chip stays put: it belongs to the dictation just cancelled.
    private func follow() {
        guard visible, !following, view.phase != "cancelled", style == .cursorBubble else { return }
        following = true
        let generation = followGeneration
        followQueue.async { [weak self] in
            let read = Self.readFocus()  // nil: the lookup failed, which is not a move
            DispatchQueue.main.async {
                guard let self, generation == self.followGeneration else { return }
                self.following = false
                guard let now = read, self.visible, self.view.phase != "cancelled", now != self.focus
                else { return }
                self.focus = now
                if self.place() { self.position() }
            }
        }
    }

    /// Where the bubble anchors for the current focus: the screen, the caret
    /// (real or assumed), or a tall pane. False when there is no screen.
    @discardableResult
    private func place() -> Bool {
        let style = style
        let location = (focus.caret ?? focus.box).map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) ?? NSScreen.main
        else { return false }
        self.screen = screen
        target = nil
        pane = nil
        if style == .cursorBubble {
            let tall = focus.box.map { $0.height > screen.visibleFrame.height * 0.4 } ?? true
            if let caret = focus.caret {
                target = caret
            } else if let box = focus.box, !tall {
                // A one-line caret's height, centred, at the start of an empty field.
                target = NSRect(x: focus.atStart ? box.minX + 16 : box.midX, y: box.midY - 9, width: 1, height: 18)
            } else {
                pane = focus.box
            }
        }
        view.style = style == .cursorBubble && target == nil ? .compactBottom : style
        return true
    }

    private func position() {
        guard let screen else { return }
        let area = screen.visibleFrame
        var size = view.phase == "cancelled" ? NSSize(width: 214, height: 34) : view.compactSize
        size.width = min(size.width, area.width - 16)
        let top = min(area.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        var x: CGFloat, y: CGFloat
        view.tailBelow = true
        // The tail tip sits 8 pt right of the caret and 8 pt clear of it.
        var tipX: CGFloat?
        if let target {
            let tail = view.hasTail ? 0 : PillView.tail  // keep the body still when the tail goes
            tipX = target.midX + 8
            x = tipX! - PillView.tipInset
            y = target.maxY + 8 + tail
            if y + size.height > top - 8 {  // no room above: down and to the right
                y = target.minY - 8 - tail - size.height
                view.tailBelow = false
            }
        } else {
            let base = pane.map { area.intersection($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? area
            x = base.midX - size.width / 2
            y = base.minY + 20
        }
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        y = min(max(y, area.minY + 8), top - size.height - 8)
        // The tail's base, as far along as keeps its tip on the caret after clamping.
        view.tailX = min(max((tipX ?? (x + size.width / 2)) - x + PillView.tail + 3, PillView.tail + 9),
                         size.width - 12)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        undoButton.frame = NSRect(x: size.width - 92, y: 6, width: 80, height: 22)
        panel.invalidateShadow()
    }

    /// The insertion caret where the focused app exposes it, else the focused
    /// element's frame (in a terminal such as Ghostty, the split being typed in),
    /// in Cocoa coordinates. One focused-element lookup, so a hung app blocks the
    /// main thread for one AX timeout, not two.
    private static func focused() -> Focus { readFocus() ?? Focus() }

    /// As `focused()`, but nil when the focused element could not be read at all
    /// (an AX error or timeout), so a follow-up read keeps the last good focus.
    private static func readFocus() -> Focus? {
        // Read at recording start, then by follow() off the main thread.
        // Apple: kAXBoundsForRangeParameterizedAttribute returns screen coordinates.
        enableElectronAccessibility()
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
              let primary = NSScreen.screens.first
        else { return nil }
        let element = focused as! AXUIElement
        var result = Focus()
        let flip = { (rect: CGRect) in
            NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        var frame: CGRect?  // the element's, in accessibility (top-left) coordinates
        var position = CGPoint.zero, size = CGSize.zero
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
           AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
           AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
           size.width >= 120, size.height >= 20 {
            frame = CGRect(origin: position, size: size)
            result.box = flip(CGRect(origin: position, size: size))
        }
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
           let selected, CFGetTypeID(selected) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(selected as! AXValue, .cfRange, &range) {
                result.caret = caret(element, range, in: frame).map(flip)
                // Enter pressed in an empty field leaves only line breaks to measure.
                result.atStart = range.location == 0 || result.caret == nil && range.location <= 64
                    && string(element, CFRange(location: 0, length: range.location))?.allSatisfy(\.isNewline) == true
            }
        }
        return result
    }

    /// The caret at the start of `range`, in accessibility coordinates. Native
    /// text views and Chromium text areas answer for the empty range there.
    /// Chromium's rich text fields do not (measured 2026-10-07): Chrome, Brave and
    /// Claude's message box answer through text markers only, and some fields
    /// for whole characters only, so the character before the caret is measured.
    /// The caret sits at its right edge or, past line breaks, at the start of a
    /// line below it: a line break itself has no usable bounds.
    private static func caret(_ element: AXUIElement, _ range: CFRange, in frame: CGRect?) -> CGRect? {
        let location = range.location
        if let rect = bounds(element, CFRange(location: location, length: 0)) { return rect }
        // The marker is the document's selection, so it must sit in this field.
        if range.length == 0, let rect = markerCaret(element),
           frame.map({ $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.minX, y: rect.midY)) }) ?? true {
            return rect
        }
        guard location > 0 else { return nil }
        // Enough text to reach back past the line breaks to where the line of text
        // before them starts.
        let start = max(0, location - 512)
        let before = string(element, CFRange(location: start, length: location - start)) ?? ""
        let breaks = before.reversed().prefix(while: \.isNewline)
        guard !breaks.isEmpty else {
            guard let rect = bounds(element, CFRange(location: location - 1, length: 1)) else { return nil }
            return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
        }
        let text = before.dropLast(breaks.count)
        guard let last = text.last else { return nil }  // only line breaks: the empty-field estimate
        let lastLength = last.utf16.count
        let lastStart = location - breaks.reduce(0) { $0 + $1.utf16.count } - lastLength
        guard let rect = bounds(element, CFRange(location: lastStart, length: lastLength)) else { return nil }
        // Where that line of text starts: its left edge, else the empty-field estimate's.
        let newline = text.lastIndex(where: \.isNewline)
        let lineStart = newline.map { start + text[...$0].utf16.count } ?? (start == 0 ? 0 : nil)
        let first = lineStart.flatMap { bounds(element, CFRange(location: $0, length: 1)) }
        let left = first?.minX ?? frame.map { $0.minX + 16 } ?? rect.minX
        // The line pitch, from the line above it when that has text: the glyph
        // height alone falls short of it (15 pt for 22 pt lines).
        var pitch = rect.height
        if let newline, let first, newline > text.startIndex,
           case let above = text[text.index(before: newline)], !above.isNewline,
           let prior = bounds(element, CFRange(location: start + text[..<newline].utf16.count - above.utf16.count,
                                               length: above.utf16.count)),
           first.minY > prior.minY {
            pitch = first.minY - prior.minY
        }
        return CGRect(x: left, y: rect.minY + pitch * CGFloat(breaks.count), width: 1, height: rect.height)
    }

    /// The screen rect of `range` in `element`, or nil when the app has none.
    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let selection = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, selection, &value) == .success
        else { return nil }
        return rect(value)
    }

    /// The caret by text markers (Chromium, WebKit): the empty range at it,
    /// else the character before it, or after a line break the line it starts.
    /// For a moment after accessibility is switched on, Chromium answers line
    /// or paragraph boxes and steps markers a whole box at a time; those are
    /// refused, and the next read finds the caret.
    private static func markerCaret(_ element: AXUIElement) -> CGRect? {
        var selected: CFTypeRef?, previous: CFTypeRef?, text: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selected) == .success,
              let selected, CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        let caret = AXTextMarkerRangeCopyStartMarker(selected as! AXTextMarkerRange)
        let here = markerBounds(element, AXTextMarkerRangeCreate(nil, caret, caret))
        if let here, here.width < 1 { return here }
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXPreviousTextMarkerForTextMarker" as CFString, caret, &previous) == .success,
              let previous, CFGetTypeID(previous) == AXTextMarkerGetTypeID()
        else { return nil }
        let before = AXTextMarkerRangeCreate(nil, previous as! AXTextMarker, caret)
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, before, &text) == .success,
              let string = text as? String, string.count == 1, let character = string.first
        else { return nil }
        if character.isNewline { return here.map { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) } }
        return markerBounds(element, before).map { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }
    }

    /// The screen rect of a text-marker range, or nil when the app has none.
    private static func markerBounds(_ element: AXUIElement, _ range: AXTextMarkerRange) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, range, &value) == .success
        else { return nil }
        return rect(value)
    }

    /// A rect an accessibility query answered, or nil when it has no height.
    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        var rect = CGRect.zero
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0
        else { return nil }
        return rect
    }

    /// The text of `range` in `element`, or nil when the app has none.
    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard let selection = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, selection, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Electron builds its accessibility tree only for an assistive client
    /// that asks: AXManualAccessibility on the app element (Electron docs,
    /// "Accessibility"). Without it the focused element may carry no text
    /// ranges. Asked on every read, not once per app: Claude was found
    /// answering line boxes only, minutes after v2t had asked (2026-10-07).
    /// Native apps reject the attribute, which is harmless.
    private static func enableElectronAccessibility() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func hide() {
        guard visible else { return }
        visible = false
        ticker?.invalidate()
        ticker = nil
        follower?.invalidate()
        follower = nil
        followGeneration += 1
        following = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
        }
    }
}

/// Input levels scroll while recording; transcription travels across the bars;
/// cleanup pulses in place. Optional live words have no placeholder/status text.
final class PillView: NSView {
    var style = PillStyle.cursorBubble
    var phase = "idle" {
        didSet { if phase == "cleaning" && oldValue != "cleaning" { cleaningSince = CACurrentMediaTime() } }
    }
    private var cleaningSince = CACurrentMediaTime()
    var partial = ""
    private var bars = [CGFloat](repeating: 0, count: 64)
    private var loudest: Double?  // since the last tick
    var tailBelow = true
    var tailX: CGFloat = 0  // the middle of the tail's base, from the bubble's left edge
    var hasTail: Bool { style == .cursorBubble && phase != "cancelled" }
    /// The tail tip's distance from the bubble's left edge with the base's middle
    /// at its leftmost (tail + 9 pt in): the tip runs tail + 3 pt left of it.
    static let tipInset: CGFloat = 6

    var compactSize: NSSize {
        // Reuse the waveform-only pill width when there are no words to show.
        let textWidth = min(252, ceil((partial as NSString).size(withAttributes: [.font: Self.font]).width))
        let width: CGFloat = phase == "recording" && !partial.isEmpty ? 16 + 44 + 12 + textWidth + 16
            : phase == "cleaning" ? 132 : 116
        return NSSize(width: width, height: 34 + (style == .cursorBubble ? Self.tail : 0))
    }

    func begin() {
        bars = [CGFloat](repeating: 0, count: bars.count)
        loudest = nil
    }

    func push(_ rms: Double) {
        loudest = max(loudest ?? 0, rms)
    }

    /// One animation frame. A tick with no new level (input blocks longer
    /// than a frame) lets the last bar fade rather than drop to nothing.
    func tick() {
        if phase == "recording" {
            let next = loudest.map(Self.height) ?? (bars.last ?? 0) * 0.8
            bars.removeFirst()
            bars.append(((bars.last ?? 0) + next) / 2)
            loudest = nil
        }
        needsDisplay = true
    }

    /// RMS (full scale 1) to bar height on a decibel scale: -50 dBFS, a quiet
    /// room, is a dot; -20 dBFS, loud close speech, fills the bar.
    static func height(_ rms: Double) -> CGFloat {
        CGFloat(min(max((20 * log10(max(rms, 1e-6)) + 50) / 30, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        var body = bounds
        let bubble = hasTail
        if bubble {
            body.size.height -= Self.tail
            if tailBelow { body.origin.y += Self.tail }
        }
        let radius = body.height / 2
        let capsule = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let tail = NSBezierPath()
        if bubble {
            // A Messages-style curl at 45 degrees: a base inside the bubble, a convex
            // sweep out to a tip down-left of it (up-left below the caret), and a
            // concave curl back.
            let t = Self.tail, edge = tailBelow ? bounds.minY : bounds.maxY
            let s: CGFloat = tailBelow ? 1 : -1  // from the tip's edge into the bubble
            let base = tailBelow ? body.minY + 3 : body.maxY - 3
            let tip = NSPoint(x: tailX - (t + 3), y: edge)
            tail.move(to: NSPoint(x: tailX + 7, y: base))
            tail.curve(to: tip, controlPoint1: NSPoint(x: tailX + 5, y: edge + s * 0.4 * t),
                       controlPoint2: NSPoint(x: tailX - 0.4 * t, y: edge))
            tail.curve(to: NSPoint(x: tailX - 5, y: base), controlPoint1: NSPoint(x: tailX - 0.3 * t, y: edge + s * 0.45 * t),
                       controlPoint2: NSPoint(x: tailX - 4, y: base - s * 5))
            tail.close()
        }
        // Bubble and tail in one translucent layer, so their overlap is not darker.
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setAlpha(0.92)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor(white: 0.07, alpha: 1).setFill()
            capsule.fill()
            tail.fill()
            context.endTransparencyLayer()
            context.restoreGState()
        }
        // The outline stops where the tail joins.
        NSGraphicsContext.saveGraphicsState()
        if bubble {
            let clip = NSBezierPath(rect: bounds)
            clip.appendRect(NSRect(x: tailX - 5, y: tailBelow ? body.minY - 1 : body.maxY - 3, width: 12, height: 4))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        NSColor(white: 1, alpha: 0.14).setStroke()
        capsule.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if phase == "cancelled" {
            drawText("Cancelled", in: NSRect(x: 16, y: 0, width: bounds.width - 112, height: bounds.height),
                     color: NSColor(white: 1, alpha: 0.9))
            return
        }
        if phase == "recording" && !partial.isEmpty {
            drawBars(in: NSRect(x: 16, y: body.minY + 10, width: 44, height: body.height - 20))
            drawWords(in: NSRect(x: 72, y: body.minY, width: body.width - 88, height: body.height))
        } else if phase == "cleaning" {
            // Count the cleanup up live, so its speed is visible every time.
            let elapsed = String(format: "%.1f s", CACurrentMediaTime() - cleaningSince)
            drawBars(in: NSRect(x: 14, y: body.minY + 9, width: 44, height: body.height - 18))
            drawText(elapsed, in: NSRect(x: 64, y: body.minY, width: body.width - 76, height: body.height),
                     color: NSColor(white: 1, alpha: 0.85))
        } else {
            drawBars(in: body.insetBy(dx: 16, dy: 9))
        }
    }

    /// Drop the oldest whole words when live text overflows the compact width.
    private func drawWords(in rect: NSRect) {
        var words = partial.split(whereSeparator: \.isWhitespace)
        var shown = words.joined(separator: " ")
        while words.count > 1 && (shown as NSString).size(withAttributes: [.font: Self.font]).width > rect.width {
            words.removeFirst()
            shown = "…" + words.joined(separator: " ")
        }
        drawText(shown, in: rect, color: NSColor(white: 1, alpha: 0.92), truncation: .byTruncatingHead)
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let tail: CGFloat = 9

    private func drawBars(in rect: NSRect) {
        let width: CGFloat = 3, gap: CGFloat = 2.5
        let count = min(bars.count, max(1, Int((rect.width + gap) / (width + gap))))
        let values: [CGFloat]
        if phase == "recording" {
            values = Array(bars.suffix(count))
            NSColor.white.setFill()
        } else {  // transcription travels; cleanup breathes in place
            let t = CACurrentMediaTime()
            values = (0..<count).map { (index: Int) -> CGFloat in
                let offset = phase == "cleaning" ? 0 : Double(index) * 0.55
                let wave: Double = (1 + sin(t * 3 + offset)) / 2
                return CGFloat(0.15 + 0.5 * wave)
            }
            NSColor(white: 1, alpha: 0.55).setFill()
        }
        var x = rect.minX + (rect.width - (CGFloat(count) * (width + gap) - gap)) / 2
        for value in values {
            let height = max(width, value * rect.height)
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: width, height: height),
                         xRadius: width / 2, yRadius: width / 2).fill()
            x += width + gap
        }
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, truncation: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        let font = Self.font
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let line = ceil(font.ascender - font.descender)
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        NSAttributedString(string: flat, attributes: attributes)
            .draw(in: NSRect(x: rect.minX, y: rect.midY - line / 2, width: rect.width, height: line))
    }
}
