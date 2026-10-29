// The runtimes a job can alternate: each arm loads one model, processes items one at a time and unloads.
import AVFoundation
import CoreML
import Foundation
import FluidAudio
import FoundationModels
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import MLXAudioSTT
import AnemllCore

/// One unit of work: a cleanup input (text chunks) or a speech clip (a WAV in the bundle).
struct Item {
  let id: String
  let chunks: [String]  // cleanup
  let file: String      // speech: file name in Res/clips
  let dur: Double       // speech: seconds of audio
}

enum ItemSet: String, Codable {
  case cleanup, speech

  /// Res/cleanup/inputs.jsonl (600 transcripts in chunks) or Res/clips/manifest.tsv (450 clips), in file order.
  func load() throws -> [Item] {
    let res = Bundle.main.resourceURL!
    switch self {
    case .cleanup:
      return try String(contentsOf: res.appendingPathComponent("cleanup/inputs.jsonl"), encoding: .utf8)
        .split(separator: "\n").map {
          let d = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
          return Item(id: d["id"] as! String, chunks: d["chunks"] as! [String], file: "", dur: 0)
        }
    case .speech:
      return try String(contentsOf: res.appendingPathComponent("clips/manifest.tsv"), encoding: .utf8)
        .split(separator: "\n").map {
          let f = $0.split(separator: "\t").map(String.init)
          return Item(id: f[0], chunks: [], file: f[1], dur: Double(f[2])!)
        }
    }
  }
}

func loadWav(_ name: String) throws -> [Float] {
  let f = try AVAudioFile(forReading: Bundle.main.resourceURL!.appendingPathComponent("clips/\(name)"))
  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
  try f.read(into: buf)
  precondition(f.processingFormat.sampleRate == 16000 && f.processingFormat.channelCount == 1)
  return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

/// An arm's spec in the job file. `model` names a folder in Documents/models (copied there by phone_push.py)
/// for the runtimes that read one; `options` carries runtime switches such as `units` or `wrap`.
struct ArmSpec: Codable {
  let id: String
  let runtime: String
  var model: String?
  var options: [String: String]?

  /// What makes two runs of an arm comparable; stored in each `start` row and checked on resume.
  var signature: String {
    let o = (options ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    return "\(runtime)|\(model ?? "")|\(o)"
  }
}

protocol Arm: AnyObject {
  var set: ItemSet { get }
  /// Loads the model and runs one warm-up item; returns fields for the `load` row.
  func load() async throws -> [String: Any]
  /// Processes one item; returns the fields of its result row (text, seconds, ...).
  func process(_ item: Item) async throws -> [String: Any]
  func unload()
}

func makeArm(_ s: ArmSpec) throws -> Arm {
  let modelDir = s.model.map { documents.appendingPathComponent("models/\($0)") }
  let opt = s.options ?? [:]
  func need() throws -> URL {
    guard let m = modelDir else { throw BenchError("arm \(s.id): runtime \(s.runtime) needs a model") }
    guard FileManager.default.fileExists(atPath: m.path) else { throw BenchError("arm \(s.id): Documents/models/\(s.model!) is missing; run phone_push.py") }
    return m
  }
  switch s.runtime {
  case "mlx": return MLXCleanup(dir: try need(), name: s.model!)
  case "anemll": return AnemllCleanup(dir: try need(), name: s.model!)
  case "afm": return AFMCleanup(wrap: opt["wrap"] == "true")
  case "parakeet-coreml": return ParakeetCoreML()
  case "mlx-stt": return MLXSpeech(dir: try need(), type: opt["model_type"] ?? "parakeet")
  case "bark": return BarkSpeech(units: computeUnits(opt["units"]))
  default: throw BenchError("arm \(s.id): unknown runtime \(s.runtime)")
  }
}

struct BenchError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

func computeUnits(_ s: String?) -> MLComputeUnits {
  switch s { case "gpu": return .cpuAndGPU; case "cpu": return .cpuOnly; case "all": return .all; default: return .cpuAndNeuralEngine }
}

/// The cleanup prompt shared by the MLX and ANEMLL arms, so they differ only in runtime.
struct CleanupPrompt {
  let system: String
  let examples: [[String]]
  init(model: String) throws {
    let res = Bundle.main.resourceURL!.appendingPathComponent("cleanup")
    let chat = try JSONSerialization.jsonObject(with: Data(contentsOf: res.appendingPathComponent("chat.json"))) as! [String: Any]
    var sys = chat["system"] as! String
    if model.lowercased().contains("qwen3") { sys += " /no_think" }
    system = sys
    examples = chat["examples"] as! [[String]]
  }
  /// About 1.5 x the source tokens + 64, as on the Mac.
  static func maxTokens(_ text: String) -> Int { Int(Double(text.count) * 0.4) + 64 }
  static func stripThink(_ s: String) -> String {
    var o = s
    if let r = o.range(of: "</think>") { o = String(o[r.upperBound...]) }
    return o.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

let warmText = "um so I think we should uh ship it"

// MARK: - cleanup arms

final class MLXCleanup: Arm, @unchecked Sendable {
  let set = ItemSet.cleanup
  let dir: URL, prompt: CleanupPrompt
  var container: ModelContainer?
  init(dir: URL, name: String) { self.dir = dir; prompt = try! CleanupPrompt(model: name) }

  func load() async throws -> [String: Any] {
    MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
    container = try await loadModelContainer(from: dir, using: #huggingFaceTokenizerLoader())
    _ = try await clean(warmText)
    return [:]
  }

  func clean(_ text: String) async throws -> (String, Double, Int, Bool) {
    var msgs: [Chat.Message] = [.system(prompt.system)]
    for e in prompt.examples { msgs.append(.user(e[0])); msgs.append(.assistant(e[1])) }
    msgs.append(.user(text))
    let maxT = CleanupPrompt.maxTokens(text)
    return try await container!.perform { ctx in
      let input = try await ctx.processor.prepare(input: UserInput(chat: msgs, additionalContext: ["enable_thinking": false]))
      let start = ContinuousClock.now
      var ttft = -1.0, n = 0
      let r = try MLXLMCommon.generate(input: input, parameters: GenerateParameters(maxTokens: maxT, temperature: 0), context: ctx) { toks in
        if ttft < 0 { ttft = (ContinuousClock.now - start).seconds }
        n = toks.count
        return .more
      }
      return (CleanupPrompt.stripThink(r.output), ttft, n, n >= maxT)
    }
  }

  func process(_ item: Item) async throws -> [String: Any] {
    var outs: [String] = [], ttft = 0.0, toks = 0, limited = 0
    for (k, c) in item.chunks.enumerated() {
      let (o, tf, n, lim) = try await clean(c)
      outs.append(o); toks += n; limited += lim ? 1 : 0
      if k == 0 { ttft = tf }
    }
    return ["clean": outs.joined(separator: " "), "ttft": ttft, "tokens": toks, "limited": limited, "chunks": item.chunks.count, "errors": [String]()]
  }

  func unload() { container = nil; MLX.GPU.clearCache() }
}

final class AnemllCleanup: Arm, @unchecked Sendable {
  let set = ItemSet.cleanup
  let dir: URL, prompt: CleanupPrompt
  var tokenizer: AnemllCore.Tokenizer?
  var im: InferenceManager?
  init(dir: URL, name: String) { self.dir = dir; prompt = try! CleanupPrompt(model: name) }

  func load() async throws -> [String: Any] {
    let config = try YAMLConfig.load(from: dir.appendingPathComponent("meta.yaml").path)
    tokenizer = try await AnemllCore.Tokenizer(modelPath: config.tokenizerModel, template: config.modelPrefix.lowercased().contains("qwen") ? "qwen" : "default", debugLevel: 0)
    let models = try await ModelLoader(progressDelegate: nil).loadModel(from: config)
    im = try InferenceManager(models: models, contextLength: config.contextLength, batchSize: config.batchSize,
      splitLMHead: config.splitLMHead, debugLevel: 0, v110: config.configVersion == "0.1.1", argmaxInModel: config.argmaxInModel,
      slidingWindow: config.slidingWindow, updateMaskPrefill: config.updateMaskPrefill, prefillDynamicSlice: config.prefillDynamicSlice,
      modelPrefix: config.modelPrefix, vocabSize: config.vocabSize, lmHeadChunkSizes: config.lmHeadChunkSizes)
    _ = try await clean(warmText)
    return [:]
  }

  func clean(_ text: String) async throws -> (String, Double, Int) {
    let tok = tokenizer!
    var msgs: [AnemllCore.Tokenizer.ChatMessage] = [.system(prompt.system)]
    for e in prompt.examples { msgs.append(.user(e[0])); msgs.append(.assistant(e[1])) }
    msgs.append(.user(text))
    let toks = tok.applyChatTemplate(input: msgs, addGenerationPrompt: true)
    let (gen, prefill, _) = try await im!.generateResponse(initialTokens: toks, temperature: 0, maxTokens: CleanupPrompt.maxTokens(text),
                                                         eosTokens: tok.eosTokenIds, tokenizer: tok)
    return (CleanupPrompt.stripThink(tok.decode(tokens: gen)), prefill, gen.count)
  }

  func process(_ item: Item) async throws -> [String: Any] {
    var outs: [String] = [], ttft = 0.0, n = 0
    for (k, c) in item.chunks.enumerated() {
      let (o, p, g) = try await clean(c); outs.append(o); n += g
      if k == 0 { ttft = p }
    }
    return ["clean": outs.joined(separator: " "), "ttft": ttft, "tokens": n, "chunks": item.chunks.count, "errors": [String]()]
  }

  func unload() { im?.unload(); im = nil; tokenizer = nil }
}

/// Apple Foundation Models. Options: `wrap: "true"` frames each chunk as "Dictation: … Cleaned:" under
/// the permissive guardrails, which stops most refusals.
final class AFMCleanup: Arm, @unchecked Sendable {
  let set = ItemSet.cleanup
  let wrap: Bool
  var model: SystemLanguageModel?
  var instructions = ""
  init(wrap: Bool) { self.wrap = wrap }

  func load() async throws -> [String: Any] {
    instructions = try String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("cleanup/instructions.txt"), encoding: .utf8)
    let m = wrap ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
    guard case .available = m.availability else { throw BenchError("Apple Foundation Models unavailable: \(m.availability)") }
    model = m
    let warm = LanguageModelSession(model: m, instructions: instructions)
    warm.prewarm()
    _ = try? await warm.respond(to: warmText, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 64))
    return ["availability": "\(m.availability)"]
  }

  func process(_ item: Item) async throws -> [String: Any] {
    var outs: [String] = [], errs: [String] = []
    let t = ContinuousClock.now
    var firstChunkS = 0.0
    for (k, c) in item.chunks.enumerated() {
      // cap runaway generations: a faithful cleanup is about as long as its input
      let opts = GenerationOptions(sampling: .greedy, maximumResponseTokens: max(64, c.split(separator: " ").count * 3))
      let session = LanguageModelSession(model: model!, instructions: instructions)
      let prompt = wrap ? "Dictation: \(c)\nCleaned:" : c
      do {
        let r: String = try await withThrowingTaskGroup(of: String.self) { g in
          g.addTask { try await session.respond(to: prompt, options: opts).content }
          g.addTask { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
          let first = try await g.next()!; g.cancelAll(); return first
        }
        outs.append(r)
      } catch { outs.append(c); errs.append(error is CancellationError ? "timeout30s" : "\(error)") }
      if k == 0 { firstChunkS = (ContinuousClock.now - t).seconds }
    }
    return ["clean": outs.joined(separator: " "), "first_chunk_s": firstChunkS, "chunks": item.chunks.count, "errors": errs]
  }

  func unload() { model = nil }
}

// MARK: - speech arms

/// Parakeet TDT v3 through FluidAudio on Core ML, with the int8 encoder bundled in Res/models.
final class ParakeetCoreML: Arm, @unchecked Sendable {
  let set = ItemSet.speech
  var mgr: AsrManager?

  func load() async throws -> [String: Any] {
    let models = try AsrModels.loadLocal(from: Bundle.main.resourceURL!.appendingPathComponent("models"), version: .v3, encoderPrecision: .int8V2)
    let m = AsrManager(config: .default)
    try await m.loadModels(models)
    mgr = m
    var st = TdtDecoderState.make()
    _ = try await m.transcribe(try loadWav(try ItemSet.speech.load()[0].file), decoderState: &st)
    return [:]
  }

  func process(_ item: Item) async throws -> [String: Any] {
    let samples = try loadWav(item.file)
    var state = TdtDecoderState.make()
    let t = ContinuousClock.now
    let out = try await mgr!.transcribe(samples, decoderState: &state)
    return ["text": out.text, "dur": item.dur, "s": (ContinuousClock.now - t).seconds]
  }

  func unload() { mgr = nil }
}

/// A speech model on MLX through mlx-audio-swift. Options: `model_type` (default parakeet), since the
/// type is not inferred from the folder name.
final class MLXSpeech: Arm, @unchecked Sendable {
  let set = ItemSet.speech
  let dir: URL, type: String
  var model: (any STTGenerationModel)?
  init(dir: URL, type: String) { self.dir = dir; self.type = type }

  func load() async throws -> [String: Any] {
    MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
    let m = try await STT.loadModel(modelRepo: dir.path, modelType: type)
    // the clips are 16 kHz and the library leaves resampling to the caller
    guard m.sampleRate == 16000 else { throw BenchError("\(type) expects \(m.sampleRate) Hz audio; the bench clips are 16 kHz") }
    model = m
    _ = m.generate(audio: MLXArray(try loadWav(try ItemSet.speech.load()[0].file)), generationParameters: STTGenerateParameters())
    return [:]
  }

  func process(_ item: Item) async throws -> [String: Any] {
    let samples = try loadWav(item.file)
    let t = ContinuousClock.now
    let out = model!.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters())
    return ["text": out.text, "dur": item.dur, "s": (ContinuousClock.now - t).seconds]
  }

  func unload() { model = nil; MLX.GPU.clearCache() }
}

/// Bark 3.0: Core ML encoder (bundled in Res/bark) plus a Swift TDT decoder. Options: `units` ane|gpu|cpu|all.
final class BarkSpeech: Arm, @unchecked Sendable {
  let set = ItemSet.speech
  let units: MLComputeUnits
  var bark: BarkTranscriber?
  init(units: MLComputeUnits) { self.units = units }

  func load() async throws -> [String: Any] {
    let b = try BarkTranscriber(folder: Bundle.main.resourceURL!.appendingPathComponent("bark"), units: units)
    bark = b
    _ = try b.transcribe(try loadWav(try ItemSet.speech.load()[0].file))
    return ["units": units.rawValue]
  }

  func process(_ item: Item) async throws -> [String: Any] {
    let samples = try loadWav(item.file)
    let t = ContinuousClock.now
    let text = try bark!.transcribe(samples)
    return ["text": text, "dur": item.dur, "s": (ContinuousClock.now - t).seconds]
  }

  func unload() { bark = nil }
}
