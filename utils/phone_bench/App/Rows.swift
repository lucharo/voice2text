import Foundation
import UIKit
import os

/// Bytes the app may still allocate before Jetsam (iOS only).
func availMB() -> Double { Double(os_proc_available_memory()) / 1e6 }

/// The app's physical footprint, the number Jetsam compares against its limit.
func footprintMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
  }
  return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : -1
}

let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

extension Duration { var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 } }

/// One append-only JSONL result file in Documents. Every row records when and in what state it ran
/// (time, thermal state, Low Power Mode, battery, charging), so runs can be compared fairly.
/// On open it reads back the keys of the items already done, which is all a relaunch needs to resume.
final class Rows: @unchecked Sendable {
  let url: URL
  private let out: FileHandle
  private let lock = NSLock()
  private(set) var done = Set<String>()
  private(set) var ended = false

  init(_ name: String) {
    url = documents.appendingPathComponent(name)
    if let bytes = try? Data(contentsOf: url) {
      // decode leniently, so a crash mid-character cannot hide the whole history
      for l in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {  // a row cut short by a crash fails to parse and is skipped
        guard let d = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { continue }
        let ev = d["event"] as? String
        if ev == "clean" || ev == "clip", let k = (d["key"] ?? d["id"]) as? String { done.insert(k) }
        if ev == "end" { ended = true }
      }
    }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    out = try! FileHandle(forWritingTo: url)
    // a crash between a row and its newline leaves the file open-ended; close it so the next row starts a new line
    if out.seekToEndOfFile() > 0, let h = try? FileHandle(forReadingFrom: url) {
      try? h.seek(toOffset: out.offsetInFile - 1)
      if h.readData(ofLength: 1) != Data("\n".utf8) { out.write(Data("\n".utf8)) }
      try? h.close()
    }
  }

  func emit(_ d: [String: Any]) {
    lock.lock(); defer { lock.unlock() }
    var row = d
    UIDevice.current.isBatteryMonitoringEnabled = true
    let pi = ProcessInfo.processInfo
    row["t"] = Date().timeIntervalSince1970
    row["avail_mb"] = row["avail_mb"] ?? availMB()
    row["thermal"] = row["thermal"] ?? pi.thermalState.rawValue
    row["low_power"] = pi.isLowPowerModeEnabled
    row["battery"] = UIDevice.current.batteryLevel
    row["charging"] = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    let ev = row["event"] as? String
    if ev == "clean" || ev == "clip", let k = (row["key"] ?? row["id"]) as? String { done.insert(k) }
    if ev == "end" { ended = true }
    guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
    let line = String(data: data, encoding: .utf8)! + "\n"
    print("V2TROW " + line, terminator: "")
    out.seekToEndOfFile(); out.write(line.data(using: .utf8)!); try? out.synchronize()
  }

  private var hb: DispatchSourceTimer?
  private let born = Date()

  /// Every 10 s from a background queue, so a blocked main thread still logs and a suspended app shows as a gap.
  /// Also logs each app-state change: a lock or an app switch shows up as resign_active / background rows.
  func startHeartbeat() {
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hb", qos: .utility))
    t.schedule(deadline: .now() + 10, repeating: 10)
    t.setEventHandler { [weak self] in
      guard let self else { return }
      self.emit(["event": "hb", "since_launch": Date().timeIntervalSince(self.born), "mb": footprintMB()])
    }
    t.resume(); hb = t
    let nc = NotificationCenter.default, q = OperationQueue()
    for (n, label) in [(UIApplication.willResignActiveNotification, "resign_active"), (UIApplication.didEnterBackgroundNotification, "background"),
                       (UIApplication.willEnterForegroundNotification, "foreground"), (UIApplication.didBecomeActiveNotification, "active"),
                       (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"), (UIApplication.didReceiveMemoryWarningNotification, "memory_warning")] {
      observers.append(nc.addObserver(forName: n, object: nil, queue: q) { [weak self] _ in
        guard let self else { return }
        self.emit(["event": "app", "state": label, "since_launch": Date().timeIntervalSince(self.born), "mb": footprintMB()])
      })
    }
  }

  private var observers: [NSObjectProtocol] = []
  deinit {
    hb?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }
}
