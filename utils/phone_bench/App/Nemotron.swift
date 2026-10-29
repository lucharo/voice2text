// NVIDIA's Nemotron-Labs Unified ASR 0.6B through FluidAudio (#85): one checkpoint, offline or buffered
// streaming, 25 European languages chosen by a prompt. The same managers and feeding as the Mac grid's
// `fluidaudio` runtime (utils/asr_grid/fa_helper), so phone and Mac rows compare.
import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Options: `mode` offline (default) or stream; `precision` int8 (default) or fp16; `context` the streaming
/// encoder's left,chunk,right in 80 ms frames (default 70,7,7, 1.12 s latency); `lang` clip (default: es for
/// the FLEURS clips, whose ids are all digits, en for LibriSpeech), auto, or a language code.
///
/// The model folder holds FluidInference/nemotron-labs-unified-asr-0.6b-coreml's `coreml/` files: the
/// decoder, joint_decision_single_step, vocab.json, metadata.json and the encoder the options name.
///
/// Offline rows: `s` is the decode with the audio in memory. Stream rows: the clip is appended one encoder
/// chunk at a time and decoded as each chunk arrives, as a live preview would; `s` is release to final text
/// (the last part-chunk plus the held-back right context), `feed_s` all the steps before release, `step_p50`
/// and `step_p90` one step's cost. A change of language prompt reloads the encoder outside the timing and
/// says so in `reload_s`.
final class NemotronUnified: Arm, @unchecked Sendable {
  let set = ItemSet.speech
  let dir: URL, stream: Bool, precision: UnifiedEncoderPrecision, context: [Int], lang: String
  var offline: UnifiedAsrManager?
  var streaming: StreamingUnifiedAsrManager?
  var config: UnifiedConfig?
  var loadedLang: NemotronUnifiedLanguage?

  init(dir: URL, options: [String: String]) {
    self.dir = dir
    stream = options["mode"] == "stream"
    precision = UnifiedEncoderPrecision(rawValue: options["precision"] ?? "int8") ?? .int8
    let ctx = (options["context"] ?? "70,7,7").split(separator: ",").compactMap { Int($0) }
    context = ctx.count == 3 ? ctx : [70, 7, 7]
    lang = options["lang"] ?? "clip"
  }

  func language(for item: Item) throws -> NemotronUnifiedLanguage {
    if lang == "clip" { return item.id.allSatisfy(\.isNumber) ? .es : .en }
    guard let l = NemotronUnifiedLanguage(rawValue: lang) else { throw BenchError("nemotron-unified: unknown lang \(lang)") }
    return l
  }

  /// Loads the encoder with this language prompt (the prompt is fixed per manager).
  func ensure(_ l: NemotronUnifiedLanguage) async throws {
    guard l != loadedLang else { return }
    unload()
    if stream {
      let c = UnifiedConfig(leftFrames: context[0], chunkFrames: context[1], rightFrames: context[2],
                            family: .nemotronMultilingual(l))
      let m = StreamingUnifiedAsrManager(config: c, encoderPrecision: precision)
      try await m.loadModels(from: dir)
      streaming = m
      config = c
    } else {
      let m = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(l)), encoderPrecision: precision)
      try await m.loadModels(from: dir)
      offline = m
    }
    loadedLang = l
  }

  func load() async throws -> [String: Any] {
    let first = try ItemSet.speech.load()[0]
    try await ensure(try language(for: first))
    _ = try await run(try loadWav(first.file))
    return [:]
  }

  func run(_ samples: [Float]) async throws -> [String: Any] {
    if let m = offline {
      let t = ContinuousClock.now
      let text = try await m.transcribe(samples)
      return ["text": text, "s": (ContinuousClock.now - t).seconds]
    }
    guard let m = streaming, let c = config else { throw BenchError("nemotron-unified: not loaded") }
    try await m.reset()
    let chunk = c.chunkSamples, first = c.chunkSamples + c.rightSamples
    let full = samples.count / chunk * chunk
    var steps: [Double] = []
    var feed = 0.0, fed = 0
    while fed < full {
      try await m.appendAudio(pcm(samples[fed..<(fed + chunk)]))
      fed += chunk
      let t = ContinuousClock.now
      try await m.processBufferedAudio()
      let dt = (ContinuousClock.now - t).seconds
      feed += dt
      if fed >= first { steps.append(dt) }
    }
    let t = ContinuousClock.now
    if fed < samples.count { try await m.appendAudio(pcm(samples[fed..<samples.count])) }
    let text = try await m.finish()
    let wait = (ContinuousClock.now - t).seconds
    let sorted = steps.sorted()
    func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))] }
    return ["text": text, "s": wait, "feed_s": feed, "steps": steps.count, "step_p50": q(0.5), "step_p90": q(0.9)]
  }

  func process(_ item: Item) async throws -> [String: Any] {
    var row: [String: Any] = [:]
    let l = try language(for: item)
    if l != loadedLang {
      let t = ContinuousClock.now
      try await ensure(l)
      row["reload_s"] = (ContinuousClock.now - t).seconds
    }
    let out = try await run(try loadWav(item.file))
    return row.merging(out) { a, _ in a }.merging(["dur": item.dur]) { a, _ in a }
  }

  func unload() { offline = nil; streaming = nil; config = nil; loadedLang = nil }

  private func pcm(_ s: ArraySlice<Float>) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
                             frameCapacity: AVAudioFrameCount(max(1, s.count)))!
    b.frameLength = AVAudioFrameCount(s.count)
    s.withUnsafeBufferPointer { if let p = $0.baseAddress { b.floatChannelData![0].update(from: p, count: s.count) } }
    return b
  }
}
