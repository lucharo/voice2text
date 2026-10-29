// A batch job the app works through by itself, resuming from its result files after any relaunch.
import Foundation
import MLX

/// The job file (Documents/job.json). See utils/phone_bench/README.md for the format.
struct JobSpec: Codable {
  let name: String
  let set: ItemSet
  var offset: Int?
  var limit: Int?
  var rounds: Int?   // passes over the items; speech runs used 3
  let block: Int     // items per arm before switching
  var order: String? // abba (default), alternate, sequential
  let arms: [ArmSpec]

  static let order = ["abba", "alternate", "sequential"]

  func resultFile(_ arm: ArmSpec) -> String { "\(name).\(arm.id).jsonl" }
  var logFile: String { "\(name).log.jsonl" }

  /// The items every arm processes, in order, each with a key unique across rounds.
  func items() throws -> [(key: String, round: Int, item: Item)] {
    let all = try set.load()
    let lo = min(offset ?? 0, all.count), hi = min(lo + (limit ?? all.count), all.count)
    let r = rounds ?? 1
    return (1...max(r, 1)).flatMap { round in all[lo..<hi].map { (key: r > 1 ? "\(round)|\($0.id)" : $0.id, round: round, item: $0) } }
  }

  /// The order blocks run in, as (arm index, block index). With abba, rounds alternate which arm goes first,
  /// so neither arm always runs on a phone the other has just warmed up.
  func schedule(itemCount n: Int) -> [(arm: Int, block: Int)] {
    let blocks = (n + block - 1) / block
    switch order ?? "abba" {
    case "sequential": return arms.indices.flatMap { a in (0..<blocks).map { (arm: a, block: $0) } }
    case "alternate": return (0..<blocks).flatMap { k in arms.indices.map { (arm: $0, block: k) } }
    default: return (0..<blocks).flatMap { k in (k % 2 == 0 ? Array(arms.indices) : arms.indices.reversed()).map { (arm: $0, block: k) } }
    }
  }

  func validate() throws {
    guard block > 0 else { throw BenchError("block must be at least 1") }
    guard (offset ?? 0) >= 0, (limit ?? 0) >= 0, (rounds ?? 1) >= 1 else { throw BenchError("offset and limit must be >= 0, rounds >= 1") }
    guard !arms.contains(where: { $0.id == "log" }) else { throw BenchError("arm id log is reserved for the job log") }
    guard !arms.isEmpty, Set(arms.map(\.id)).count == arms.count else { throw BenchError("arms must be non-empty with unique ids") }
    guard Self.order.contains(order ?? "abba") else { throw BenchError("order must be one of \(Self.order)") }
  }
}

/// Runs a job to the end. The next block to run is derived from the result files alone (the first scheduled
/// block with an item its arm has not done), so a relaunch after a crash, a kill or a reboot picks up there.
final class JobRunner: @unchecked Sendable {
  let spec: JobSpec
  let log: Rows
  let files: [Rows]
  let status: (Progress) -> Void

  /// What the app's screen shows, so progress can be read off the phone without the Mac.
  struct ArmProgress: Identifiable { let id: String; let done: Int; let total: Int }
  struct Progress {
    var line: String
    var arms: [ArmProgress] = []
    var eta: Date? = nil
    var perMin: Double? = nil
  }

  private var stamps: [Date] = []  // when each item finished this launch, for the rate

  private func report(_ line: String, total: Int) {
    let now = Date()
    stamps = stamps.filter { now.timeIntervalSince($0) < 1800 }
    var p = Progress(line: line, arms: zip(spec.arms, files).map { ArmProgress(id: $0.id, done: $1.done.count, total: total) })
    let left = p.arms.reduce(0) { $0 + max($1.total - $1.done, 0) }
    if stamps.count >= 5, let first = stamps.first, now.timeIntervalSince(first) >= 60 {
      let rate = Double(stamps.count - 1) / now.timeIntervalSince(first)
      p.perMin = rate * 60
      p.eta = now.addingTimeInterval(Double(left) / rate)
    }
    status(p)
  }

  init(spec: JobSpec, status: @escaping (Progress) -> Void) {
    self.spec = spec
    self.status = status
    log = Rows(spec.logFile)
    files = spec.arms.map { Rows(spec.resultFile($0)) }
  }

  func run() async throws {
    try spec.validate()
    log.startHeartbeat()
    let items = try spec.items()
    let sched = spec.schedule(itemCount: items.count)
    let pi = ProcessInfo.processInfo
    let specJSON = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(spec))) ?? [:]
    log.emit(["event": "start", "job": spec.name, "spec": specJSON, "items": items.count, "blocks": sched.count,
              "done": Dictionary(uniqueKeysWithValues: zip(spec.arms.map(\.id), files.map(\.done.count))),
              "os": ProcessInfo.processInfo.operatingSystemVersionString, "mb": footprintMB()])
    var loaded: (index: Int, arm: Arm)? = nil
    var failed = Set<Int>()  // arms whose model failed to load this launch; a relaunch tries them again
    for (bi, (a, k)) in sched.enumerated() {
      let spec = self.spec.arms[a], out = files[a]
      let todo = items[(k * self.spec.block)..<min((k + 1) * self.spec.block, items.count)].filter { !out.done.contains($0.key) }
      if todo.isEmpty || failed.contains(a) { continue }
      if let prev = out.lastStart?["signature"] as? String, prev != spec.signature {
        // resuming would mix two configurations in one file, or skip the new one as already done
        let msg = "arm \(spec.id) was \(prev) in earlier rows and is \(spec.signature) now; give the job a new name"
        out.emit(["event": "error", "arm": spec.id, "stage": "resume", "msg": msg])
        log.emit(["event": "arm_failed", "arm": spec.id, "msg": msg])
        failed.insert(a); continue
      }
      if loaded?.index != a {
        if let l = loaded { unload(l.arm, index: l.index) }
        loaded = nil
        report("loading \(spec.id)", total: items.count)
        out.emit(["event": "start", "arm": spec.id, "runtime": spec.runtime, "model": spec.model ?? "", "signature": spec.signature, "mb": footprintMB(),
                  "thermal": pi.thermalState.rawValue, "lowPower": pi.isLowPowerModeEnabled])
        let t0 = ContinuousClock.now
        do {
          let arm = try makeArm(spec)
          var row = try await arm.load()
          row["event"] = "load"; row["arm"] = spec.id; row["s"] = (ContinuousClock.now - t0).seconds; row["mb"] = footprintMB()
          out.emit(row)
          loaded = (a, arm)
        } catch {
          out.emit(["event": "error", "arm": spec.id, "stage": "load", "msg": "\(error)"])
          log.emit(["event": "arm_failed", "arm": spec.id, "msg": "\(error)"])
          failed.insert(a); continue
        }
      }
      let arm = loaded!.arm
      log.emit(["event": "block_start", "arm": spec.id, "block": k, "i": bi, "of": sched.count, "n": todo.count, "mb": footprintMB()])
      for (j, it) in todo.enumerated() {
        report("\(spec.id) block \(k + 1), item \(j + 1)/\(todo.count) · step \(bi + 1)/\(sched.count)", total: items.count)
        let t = ContinuousClock.now
        var row: [String: Any]
        do { row = try await arm.process(it.item) } catch { row = ["errors": ["\(error)"]] }
        row["event"] = arm.set == .cleanup ? "clean" : "clip"
        row["id"] = it.item.id; row["key"] = it.key; row["r"] = it.round; row["block"] = k; row["arm"] = spec.id
        if arm.set == .cleanup { row["s"] = (ContinuousClock.now - t).seconds }
        row["mb"] = footprintMB()
        out.emit(row)
        stamps.append(Date())
      }
      log.emit(["event": "block_end", "arm": spec.id, "block": k, "i": bi, "mb": footprintMB()])
      if !out.ended && items.allSatisfy({ out.done.contains($0.key) }) { out.emit(["event": "end", "arm": spec.id]) }
    }
    if let l = loaded { unload(l.arm, index: l.index) }
    // an arm finished in an earlier launch that died before writing its end row gets one now
    for (f, arm) in zip(files, spec.arms) where !f.ended && items.allSatisfy({ f.done.contains($0.key) }) { f.emit(["event": "end", "arm": arm.id]) }
    let complete = files.allSatisfy { f in items.allSatisfy { f.done.contains($0.key) } }
    log.emit(["event": complete ? "end" : "stopped", "job": spec.name,
              "done": Dictionary(uniqueKeysWithValues: zip(spec.arms.map(\.id), files.map(\.done.count))),
              "failed": failed.map { spec.arms[$0].id }])
    report(complete ? "done" : "stopped: an arm failed to load (see the log)", total: items.count)
  }

  private func unload(_ arm: Arm, index: Int) {
    arm.unload()
    files[index].emit(["event": "unload", "arm": spec.arms[index].id, "mb": footprintMB()])
  }
}
