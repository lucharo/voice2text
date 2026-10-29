import SwiftUI
import UIKit

@MainActor final class Status: ObservableObject {
  @Published var job = ""
  @Published var progress = JobRunner.Progress(line: "starting")
  @Published var detail = ""
  @Published var device = ""
  var line: String { get { progress.line } set { progress.line = newValue } }

  /// Battery, charging and thermal state, refreshed every 10 s.
  func watchDevice() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in self.readDevice() } }
    readDevice()
  }
  func readDevice() {
    let d = UIDevice.current, pi = ProcessInfo.processInfo
    let bat = d.batteryLevel < 0 ? "?" : "\(Int(d.batteryLevel * 100))%"
    let charging = d.batteryState == .charging || d.batteryState == .full
    let thermal = ["nominal", "fair", "serious", "critical"][min(pi.thermalState.rawValue, 3)]
    device = "battery \(bat)\(charging ? " charging" : "") · thermal \(thermal)\(pi.isLowPowerModeEnabled ? " · Low Power on" : "")"
  }
}

/// The job to run: `--job <file>` (in Documents) when launched with arguments, else Documents/job.json,
/// so tapping the icon after a crash or a reboot resumes the same job.
func jobURL() -> URL {
  let a = CommandLine.arguments
  return documents.appendingPathComponent(a.firstIndex(of: "--job").map { a[$0 + 1] } ?? "job.json")
}

@main struct BenchApp: App {
  @StateObject var status = Status()
  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading, spacing: 14) {
        Text("v2t phone bench\(status.job.isEmpty ? "" : ": " + status.job)").font(.headline)
        Text(status.progress.line).font(.body.monospaced())
        ForEach(status.progress.arms) { arm in
          VStack(alignment: .leading, spacing: 4) {
            HStack { Text(arm.id).font(.body.monospaced()); Spacer(); Text("\(arm.done)/\(arm.total)").font(.body.monospaced()) }
            ProgressView(value: Double(min(arm.done, arm.total)), total: Double(max(arm.total, 1)))
          }
        }
        if let eta = status.progress.eta, let rate = status.progress.perMin {
          Text("ends about \(eta.formatted(date: .omitted, time: .shortened)) · \(rate, specifier: "%.1f") items/min").font(.body.monospaced())
        }
        Text(status.device).font(.footnote.monospaced())
        Text(status.detail).font(.footnote).foregroundStyle(.secondary)
      }
      .padding()
      .task {
        // the screen must stay on: a locked or backgrounded app gets no GPU, so MLX arms stop dead
        UIApplication.shared.isIdleTimerDisabled = true
        status.detail = "Keep this app in front (Guided Access: triple-click the side button)."
        status.watchDevice()
        let url = jobURL()
        guard let data = try? Data(contentsOf: url) else { status.line = "no job at Documents/\(url.lastPathComponent); push one with phone_push.py"; return }
        let spec: JobSpec
        do { spec = try JSONDecoder().decode(JobSpec.self, from: data) } catch { status.line = "bad job file: \(error)"; return }
        let s = status
        s.job = spec.name
        let runner = JobRunner(spec: spec) { p in Task { @MainActor in s.progress = p } }
        // Off the main thread: a synchronous model load on the main actor during launch trips iOS's 20 s
        // scene-create watchdog (0x8BADF00D).
        let work = Task.detached(priority: .userInitiated) { try await runner.run() }
        do { try await work.value } catch {
          runner.log.emit(["event": "error", "msg": "\(error)"])
          status.line = "error: \(error)"
        }
      }
    }
  }
}
