// piece-bench: whole-file against pieces-while-recording, per clip, with the iPhone app's models (#112).
//
//     swift build -c release --package-path ios/tools/PieceBench
//     ios/tools/PieceBench/.build/release/piece-bench --arm nemotron --set SET.jsonl --out OUT.jsonl \
//       [--nemotron-dir DIR] [--parakeet-dir DIR] [--min-s 0] [--limit N]
//
// SET.jsonl holds one clip per line: {"id", "path", "duration_s", "lang"} (utils/asr_grid's set files). OUT.jsonl
// gets one line per clip and is resumed: clips already in it are skipped.
//
// Per clip, both ways run in the same process, in alternating order:
//   whole   the app up to build 3: the whole recording decoded after Stop. `whole_s` is that decode.
//   pieces  V2TPieces' PieceTranscriber, fed each whole 0.5 s as the app's timer feeds it, then finish(). Pieces
//           decode on the audio's own clock, so `backlog_s` is any piece work still running at Stop (a piece
//           that takes longer than the audio after it); `wait_s` = backlog_s + `finish_s`, the time from Stop
//           to text.
// Models: Nemotron Unified int8 (the app's choice on Apple Intelligence iPhones), told the clip's language,
// and Parakeet v3 int8 (every other iPhone), loaded as the app loads them (Packages/V2TSpeech/Sources/V2TSpeech/SpeechEngine.swift).
import FluidAudio
import Foundation
import V2TPieces

struct Clip: Decodable {
  let id: String
  let path: String
  let duration_s: Double
  let lang: String?
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func loadAverage() -> Double {
  var avg = [Double](repeating: 0, count: 3)
  return getloadavg(&avg, 3) > 0 ? avg[0] : -1
}

/// One loaded model with the app's decode call: 16 kHz mono floats to text.
actor Model {
  let arm: String
  private let dir: URL
  private var nemotron: [String: UnifiedAsrManager] = [:]
  private var parakeet: AsrManager?

  init(arm: String, dir: URL) {
    self.arm = arm
    self.dir = dir
  }

  /// Loads (once per language for Nemotron) and returns the load time, 0 when already loaded.
  func load(language: String) async throws -> Double {
    let t0 = now()
    switch arm {
    case "nemotron":
      let key = NemotronUnifiedLanguage(rawValue: language) ?? .en
      guard nemotron[key.rawValue] == nil else { return 0 }
      let m = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(key)), encoderPrecision: .int8)
      try await m.loadModels(from: dir)
      nemotron[key.rawValue] = m
    default:
      guard parakeet == nil else { return 0 }
      let models = try await AsrModels.loadLocal(from: dir, version: .v3, encoderPrecision: .int8V2)
      let m = AsrManager(config: .default)
      try await m.loadModels(models)
      parakeet = m
    }
    return now() - t0
  }

  func transcribe(_ samples: [Float], language: String) async throws -> String {
    switch arm {
    case "nemotron":
      let key = (NemotronUnifiedLanguage(rawValue: language) ?? .en).rawValue
      return try await nemotron[key]!.transcribe(samples)
    default:
      var state = TdtDecoderState.make()
      return try await parakeet!.transcribe(samples, decoderState: &state).text
    }
  }
}

func writeLine(_ object: [String: Any], to handle: FileHandle) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  handle.write(data + Data("\n".utf8))
}

@main
struct PieceBench {
  static func main() async throws {
    var opts: [String: String] = [:]
    let args = CommandLine.arguments
    var i = 1
    while i + 1 < args.count, args[i].hasPrefix("--") {
      opts[String(args[i].dropFirst(2))] = args[i + 1]
      i += 2
    }
    guard let arm = opts["arm"], ["nemotron", "parakeet"].contains(arm), let setPath = opts["set"], let outPath = opts["out"] else {
      FileHandle.standardError.write(Data("usage: piece-bench --arm nemotron|parakeet --set SET.jsonl --out OUT.jsonl\n".utf8))
      exit(2)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir =
      arm == "nemotron"
      ? URL(fileURLWithPath: opts["nemotron-dir"] ?? home.appending(path: ".v2t/eval/grid-models/nemotron-unified-coreml/coreml").path)
      : URL(fileURLWithPath: opts["parakeet-dir"] ?? home.appending(path: "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3").path)
    let minS = Double(opts["min-s"] ?? "0") ?? 0
    let limit = Int(opts["limit"] ?? "") ?? .max

    var done = Set<String>()
    if let existing = try? String(contentsOfFile: outPath, encoding: .utf8) {
      for line in existing.split(separator: "\n") {
        if let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = row["id"] as? String {
          done.insert(id)
        }
      }
    }
    if !FileManager.default.fileExists(atPath: outPath) { FileManager.default.createFile(atPath: outPath, contents: nil) }
    let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    try out.seekToEnd()

    let clips = try String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n")
      .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
      .filter { $0.duration_s >= minS }
      .prefix(limit)
    let model = Model(arm: arm, dir: dir)
    let converter = AudioConverter()
    let step = 8_000  // the app feeds new audio every 0.5 s
    var index = 0
    for clip in clips where !done.contains(clip.id) {
      index += 1
      let language = clip.lang ?? "en"
      let samples = try converter.resampleAudioFile(URL(fileURLWithPath: clip.path))
      let duration = Double(samples.count) / 16_000
      let loadS = try await model.load(language: language)
      if loadS > 0 { _ = try await model.transcribe(Array(samples.prefix(16_000 * 5)), language: language) }  // warm-up
      let loadBefore = loadAverage()

      var row: [String: Any] = ["id": clip.id, "duration_s": duration, "lang": language, "arm": arm, "load_s": loadS]
      func runWhole() async throws {
        let t0 = now()
        row["whole"] = try await model.transcribe(samples, language: language)
        row["whole_s"] = now() - t0
      }
      func runPieces() async throws {
        let pieces = PieceTranscriber { try await model.transcribe($0, language: language) }
        var busyUntil = 0.0
        var steps: [Double] = []
        var fed = 0
        // The app's timer ticks every 0.5 s of audio and hands over everything recorded since the last hand-over,
        // but skips a tick while the previous hand-over is still decoding (LiveTranscription.feed). Whatever
        // arrived after the last tick goes to finish().
        var tick = step
        while tick <= samples.count {
          let at = Double(tick) / 16_000
          if busyUntil <= at {
            let t0 = now()
            await pieces.add(Array(samples[fed..<tick]))
            let dt = now() - t0
            fed = tick
            if dt > 0.005 { steps.append(dt) }  // an add that decoded a piece
            busyUntil = at + dt
          }
          tick += step
        }
        // piece work still running when the recording ends is waited for
        let backlog = max(0, busyUntil - duration)
        let t0 = now()
        let (text, report) = try await pieces.finish(samples)
        let finishS = now() - t0
        row["pieces"] = text
        row["finish_s"] = finishS
        row["backlog_s"] = backlog
        row["wait_s"] = backlog + finishS
        row["piece_s"] = steps
        row["pieces_while_recording"] = report.piecesWhileRecording
        row["pieces_at_finish"] = report.piecesAtFinish
        row["fell_back"] = report.fellBack
      }
      if index % 2 == 0 {
        try await runWhole(); try await runPieces()
      } else {
        try await runPieces(); try await runWhole()
      }
      row["load_avg"] = [loadBefore, loadAverage()]
      try writeLine(row, to: out)
      let w = row["whole_s"] as! Double, p = row["wait_s"] as! Double
      print(String(format: "%4d %-44@ %6.1fs whole %.3fs pieces %.3fs (%d+%d)", index, clip.id as NSString, duration, w, p,
                   row["pieces_while_recording"] as! Int, row["pieces_at_finish"] as! Int))
    }
  }
}
