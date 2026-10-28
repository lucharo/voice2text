import SwiftUI
import UIKit

@MainActor final class Status: ObservableObject {
  @Published var line = "starting"
  @Published var detail = ""
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
      VStack(alignment: .leading, spacing: 12) {
        Text("v2t phone bench").font(.headline)
        Text(status.line).font(.body.monospaced())
        Text(status.detail).font(.footnote).foregroundStyle(.secondary)
      }
      .padding()
      .task {
        // the screen must stay on: a locked or backgrounded app gets no GPU, so MLX arms stop dead
        UIApplication.shared.isIdleTimerDisabled = true
        status.detail = "Keep this app in front (Guided Access: triple-click the side button)."
        let url = jobURL()
        guard let data = try? Data(contentsOf: url) else { status.line = "no job at Documents/\(url.lastPathComponent); push one with phone_push.py"; return }
        let spec: JobSpec
        do { spec = try JSONDecoder().decode(JobSpec.self, from: data) } catch { status.line = "bad job file: \(error)"; return }
        let s = status
        let runner = JobRunner(spec: spec) { msg in Task { @MainActor in s.line = msg } }
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
