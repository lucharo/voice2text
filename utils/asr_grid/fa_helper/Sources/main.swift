// fa-helper: FluidAudio models behind a JSON-lines pipe, for grid.py's `fluidaudio` runtime.
//
//     swift build -c release --package-path utils/asr_grid/fa_helper
//     .build/release/fa-helper --nemotron-dir DIR [--parakeet-dir DIR]
//
// One request per stdin line, one reply per stdout line prefixed "@@ " (FluidAudio logs
// to stderr, but the prefix keeps any stray stdout line from being read as a reply).
// Engines load on first use and stay loaded, so a reply's timings are warm decodes;
// `load_s` is set on the request that loaded its engine.
//
// Requests:
//   {"arm": "nemotron", "mode": "offline", "precision": "fp16"|"int8", "lang": "en"|"es"|"auto",
//    "path": "clip.wav"}
//   {"arm": "nemotron", "mode": "stream", "context": "70,7,7", "precision": ..., "lang": ..., "path": ...}
//   {"arm": "parakeet-v3", "path": ...}   FluidAudio's Parakeet v3 (Encoder_v2, int8), whole-file
//
// Offline replies: {"text", "decode_s"}. Stream replies: the audio is appended one chunk
// (the context's middle number of 80 ms frames) at a time and decoded as soon as each
// chunk arrives, as a live preview would; at release the last part-chunk is appended
// and finish() flushes the held-back right context. {"text", "partial_texts" (the
// transcript after each step, sampled), "step_s" (each call that ran an encoder
// window), "feed_s" (all calls before release), "wait_s" (release to final text)}.
// Every reply carries "peak_mem_gb": the process's peak physical footprint so far.
import AVFoundation
import CoreML
import FluidAudio
import Foundation

struct Request: Decodable {
    let arm: String
    let path: String
    var mode: String?
    var precision: String?
    var lang: String?
    var context: String?
}

func reply(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write("@@ ".data(using: .utf8)! + data + "\n".data(using: .utf8)!)
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func pcmBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        if let base = src.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
    }
    return buffer
}

func language(_ code: String?) throws -> NemotronUnifiedLanguage {
    guard let lang = NemotronUnifiedLanguage(rawValue: (code ?? "auto").lowercased()) else {
        throw NSError(domain: "fa-helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown lang \(code ?? "")"])
    }
    return lang
}

func precision(_ name: String?) -> UnifiedEncoderPrecision {
    UnifiedEncoderPrecision(rawValue: name ?? "fp16") ?? .fp16
}

func context(_ spec: String?) -> [Int] {
    let parts = (spec ?? "70,7,7").split(separator: ",").compactMap { Int($0) }
    return parts.count == 3 ? parts : [70, 7, 7]
}

@main
struct Helper {
    static func main() async {
        var nemotronDir: URL?
        var parakeetDir: URL?
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--nemotron-dir": nemotronDir = URL(fileURLWithPath: args[i + 1]); i += 1
            case "--parakeet-dir": parakeetDir = URL(fileURLWithPath: args[i + 1]); i += 1
            default: break
            }
            i += 1
        }
        let converter = AudioConverter()
        var offline: [String: UnifiedAsrManager] = [:]
        var streaming: [String: StreamingUnifiedAsrManager] = [:]
        var parakeet: AsrManager?

        while let line = readLine() {
            guard !line.isEmpty else { continue }
            do {
                let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                let samples = try converter.resampleAudioFile(URL(fileURLWithPath: request.path))
                var out: [String: Any] = [:]
                switch (request.arm, request.mode ?? "offline") {
                case ("nemotron", "offline"):
                    let key = "\(request.precision ?? "fp16")/\(request.lang ?? "auto")"
                    if offline[key] == nil {
                        let t0 = now()
                        let manager = UnifiedAsrManager(
                            config: UnifiedConfig(family: .nemotronMultilingual(try language(request.lang))),
                            encoderPrecision: precision(request.precision))
                        try await manager.loadModels(from: nemotronDir!)
                        offline[key] = manager
                        out["load_s"] = now() - t0
                    }
                    let t0 = now()
                    out["text"] = try await offline[key]!.transcribe(samples)
                    out["decode_s"] = now() - t0
                case ("nemotron", "stream"):
                    let ctx = context(request.context)
                    let key = "\(request.precision ?? "fp16")/\(request.lang ?? "auto")/\(ctx)"
                    let config = UnifiedConfig(
                        leftFrames: ctx[0], chunkFrames: ctx[1], rightFrames: ctx[2],
                        family: .nemotronMultilingual(try language(request.lang)))
                    if streaming[key] == nil {
                        let t0 = now()
                        let manager = StreamingUnifiedAsrManager(
                            config: config, encoderPrecision: precision(request.precision))
                        try await manager.loadModels(from: nemotronDir!)
                        streaming[key] = manager
                        out["load_s"] = now() - t0
                    }
                    let manager = streaming[key]!
                    try await manager.reset()
                    let chunk = config.chunkSamples
                    // the first window needs chunk + right samples; each later one, one chunk
                    let firstWindow = config.chunkSamples + config.rightSamples
                    var steps: [Double] = []
                    var partials: [String] = []
                    var feed = 0.0
                    var fed = 0
                    // A live stream decodes each chunk once it has arrived; when a step takes
                    // longer than its audio, the next one waits. busyUntil follows that on the
                    // audio clock, so a backlog at release counts in the wait.
                    var busyUntil = 0.0
                    let full = samples.count / chunk * chunk  // what arrived before release
                    while fed < full {
                        try await manager.appendAudio(pcmBuffer(samples[fed..<(fed + chunk)]))
                        fed += chunk
                        let t0 = now()
                        try await manager.processBufferedAudio()
                        let dt = now() - t0
                        feed += dt
                        busyUntil = max(busyUntil, Double(fed) / 16000) + dt
                        if fed >= firstWindow {
                            steps.append(dt)
                            partials.append(await manager.getPartialTranscript())
                        }
                    }
                    let tRelease = now()
                    if fed < samples.count {
                        try await manager.appendAudio(pcmBuffer(samples[fed..<samples.count]))
                    }
                    out["text"] = try await manager.finish()
                    let backlog = max(0, busyUntil - Double(samples.count) / 16000)
                    out["wait_s"] = backlog + (now() - tRelease)
                    out["backlog_s"] = backlog
                    out["feed_s"] = feed
                    out["step_s"] = steps
                    // every 4th partial and the last, enough to see the preview settle
                    out["partial_texts"] = partials.enumerated()
                        .filter { $0.offset % 4 == 3 || $0.offset == partials.count - 1 }.map(\.element)
                case ("parakeet-v3", _):
                    if parakeet == nil {
                        let t0 = now()
                        let models = try AsrModels.loadLocal(
                            from: parakeetDir!, version: .v3, encoderPrecision: .int8V2)
                        let manager = AsrManager(config: .default, models: models)
                        try await manager.loadModels(models)
                        parakeet = manager
                        out["load_s"] = now() - t0
                    }
                    var state = try TdtDecoderState(decoderLayers: 2)
                    let t0 = now()
                    out["text"] = try await parakeet!.transcribe(samples, decoderState: &state).text
                    out["decode_s"] = now() - t0
                default:
                    throw NSError(domain: "fa-helper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "unknown arm/mode \(request.arm)"])
                }
                out["peak_mem_gb"] = Double(SystemInfo.peakPhysicalFootprintBytes() ?? 0) / 1e9
                reply(out)
            } catch {
                reply(["error": "\(error)"])
            }
        }
    }
}
