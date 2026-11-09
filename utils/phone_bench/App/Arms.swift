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
  var chunksBy: [String: [String]] = [:]  // cleanup inputs from a job's `inputs`: the text in chunks of other sizes
}

enum ItemSet: String, Codable {
  case cleanup, speech

  /// Res/cleanup/inputs.jsonl (600 transcripts in chunks) or Res/clips/manifest.tsv (450 clips), in file order.
  /// A cleanup job's `inputs` names a file in Documents of the same shape instead, where each line may also
  /// carry `chunks_by` ({"80": [...]}), the text cut at other chunk sizes for prompt files that ask for one.
  func load(inputs: String? = nil) throws -> [Item] {
    let res = Bundle.main.resourceURL!
    switch self {
    case .cleanup:
      let url = inputs.map { documents.appendingPathComponent($0) } ?? res.appendingPathComponent("cleanup/inputs.jsonl")
      let items = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n").enumerated().map { (n, line) in
          // a job's own inputs come from outside the bundle: a bad line is an error, not a crash
          guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let id = d["id"] as? String, let chunks = d["chunks"] as? [String]
          else { throw BenchError("\(url.lastPathComponent) line \(n + 1): needs a string id and a list of chunks") }
          return Item(id: id, chunks: chunks, file: "", dur: 0, chunksBy: d["chunks_by"] as? [String: [String]] ?? [:])
        }
      guard Set(items.map(\.id)).count == items.count else { throw BenchError("\(url.lastPathComponent): ids must be unique") }
      return items
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

/// Which item set each runtime processes; JobSpec.validate refuses a mismatch.
let runtimeSet: [String: ItemSet] = ["mlx": .cleanup, "anemll": .cleanup, "afm": .cleanup,
                                     "parakeet-coreml": .speech, "mlx-stt": .speech, "bark": .speech,
                                     "nemotron-unified": .speech]

func makeArm(_ s: ArmSpec) throws -> Arm {
  let modelDir = s.model.map { documents.appendingPathComponent("models/\($0)") }
  let opt = s.options ?? [:]
  func need() throws -> URL {
    guard let m = modelDir else { throw BenchError("arm \(s.id): runtime \(s.runtime) needs a model") }
    guard FileManager.default.fileExists(atPath: m.path) else { throw BenchError("arm \(s.id): Documents/models/\(s.model!) is missing; run phone_push.py") }
    return m
  }
  switch s.runtime {
  case "mlx":
    let chat = try opt["prompt"].map { name -> ChatPrompt in
      let url = documents.appendingPathComponent("prompts/\(name)")
      guard FileManager.default.fileExists(atPath: url.path) else { throw BenchError("arm \(s.id): Documents/prompts/\(name) is missing; run phone_push.py") }
      let chat = try JSONDecoder().decode(ChatPrompt.self, from: Data(contentsOf: url))
      guard chat.examples.allSatisfy({ $0.count == 2 }) else { throw BenchError("arm \(s.id): every example in \(name) needs [raw, clean]") }
      return chat
    }
    return MLXCleanup(dir: try need(), name: s.model!, chat: chat, cpu: opt["device"] == "cpu", withSpeech: opt["speech"] == "true")
  case "anemll": return AnemllCleanup(dir: try need(), name: s.model!)
  case "afm":
    let prompt = try opt["prompt"].map { name -> AFMPrompt in
      let url = documents.appendingPathComponent("prompts/\(name)")
      guard FileManager.default.fileExists(atPath: url.path) else { throw BenchError("arm \(s.id): Documents/prompts/\(name) is missing; run phone_push.py") }
      return try JSONDecoder().decode(AFMPrompt.self, from: Data(contentsOf: url))
    }
    return AFMCleanup(wrap: opt["wrap"] == "true", prompt: prompt)
  case "parakeet-coreml": return ParakeetCoreML()
  case "mlx-stt": return MLXSpeech(dir: try need(), type: opt["model_type"] ?? "parakeet")
  case "bark": return BarkSpeech(units: computeUnits(opt["units"]))
  case "nemotron-unified": return NemotronUnified(dir: try need(), options: opt)
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

/// A chat prompt for the MLX arm (`prompt: <file>` in Documents/prompts): the system text and (raw, clean)
/// example turns, as the Mac app builds them (backends.cleanup_messages), so both arms get today's prompt.
struct ChatPrompt: Codable {
  let system: String
  let examples: [[String]]
}

/// An LLM on the GPU through mlx-swift-lm. Options: `prompt: <file>` (ChatPrompt) instead of the bundled
/// chat.json; `device: cpu` runs it on the CPU, which iOS allows in the background where it gives an app no
/// GPU; `speech: true` also keeps the bundled Parakeet Core ML model loaded, so `mb` shows both together.
/// With a prompt file, rows keep each chunk's input, output, seconds and first-token time.
final class MLXCleanup: Arm, @unchecked Sendable {
  let set = ItemSet.cleanup
  let dir: URL, prompt: CleanupPrompt, chat: ChatPrompt?, cpu: Bool, withSpeech: Bool
  var container: ModelContainer?
  var speech: ParakeetCoreML?
  init(dir: URL, name: String, chat: ChatPrompt? = nil, cpu: Bool = false, withSpeech: Bool = false) {
    self.dir = dir; prompt = try! CleanupPrompt(model: name); self.chat = chat; self.cpu = cpu; self.withSpeech = withSpeech
  }

  /// `body` on the arm's device: the CPU when asked, else MLX's default (the GPU).
  func onDevice<R>(_ body: () async throws -> R) async throws -> R {
    cpu ? try await Device.withDefaultDevice(Device(.cpu), body) : try await body()
  }

  func load() async throws -> [String: Any] {
    MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
    if withSpeech {
      let p = ParakeetCoreML()
      _ = try await p.load()
      speech = p
    }
    try await onDevice {
      container = try await loadModelContainer(from: dir, using: #huggingFaceTokenizerLoader())
      _ = try await clean(warmText)
    }
    return ["device": cpu ? "cpu" : "gpu", "speech_loaded": withSpeech]
  }

  func clean(_ text: String) async throws -> (String, Double, Int, Bool) {
    var msgs: [Chat.Message] = [.system(chat?.system ?? prompt.system)]
    for e in chat?.examples ?? prompt.examples { msgs.append(.user(e[0])); msgs.append(.assistant(e[1])) }
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
    var outs: [String] = [], ttft = 0.0, toks = 0, limited = 0, secs: [Double] = [], ttfts: [Double] = [], lims: [Bool] = []
    try await onDevice {
      for (k, c) in item.chunks.enumerated() {
        let t = ContinuousClock.now
        let (o, tf, n, lim) = try await clean(c)
        outs.append(o); toks += n; limited += lim ? 1 : 0; lims.append(lim)
        secs.append((ContinuousClock.now - t).seconds); ttfts.append(tf)
        if k == 0 { ttft = tf }
      }
    }
    var row: [String: Any] = ["clean": outs.joined(separator: " "), "ttft": ttft, "tokens": toks, "limited": limited,
                              "chunks": item.chunks.count, "errors": [String]()]
    if chat != nil { row["chunk_in"] = item.chunks; row["chunk_out"] = outs; row["chunk_s"] = secs; row["chunk_ttft"] = ttfts; row["chunk_limited"] = lims }
    return row
  }

  func unload() { container = nil; speech?.unload(); speech = nil; MLX.GPU.clearCache() }
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

/// A prompt to try for Apple Foundation Models (#126), read from Documents/prompts/<name> by the `prompt`
/// option: the instructions, how each chunk is framed (`{text}` stands for the chunk), the response cap
/// (max(min_cap, cap x the chunk's words)) and which chunk size of the item to use. Guardrails are the
/// permissive ones the app uses.
struct AFMPrompt: Codable {
  let instructions: String
  let frame: String
  var cap: Int?
  var min_cap: Int?
  var chunk_words: Int?
}

/// Apple Foundation Models. Options: `wrap: "true"` frames each chunk as "Dictation: … Cleaned:" under
/// the permissive guardrails, which stops most refusals; `prompt: <file>` uses a prompt file instead
/// (AFMPrompt), and its rows also keep each chunk's input, output and seconds, so the Mac can apply the
/// app's guards and score every chunk.
final class AFMCleanup: Arm, @unchecked Sendable {
  let set = ItemSet.cleanup
  let wrap: Bool
  let prompt: AFMPrompt?
  var model: SystemLanguageModel?
  var instructions = ""
  init(wrap: Bool, prompt: AFMPrompt? = nil) { self.wrap = wrap; self.prompt = prompt }

  func load() async throws -> [String: Any] {
    instructions = try prompt?.instructions
      ?? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("cleanup/instructions.txt"), encoding: .utf8)
    let m = wrap || prompt != nil ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
    guard case .available = m.availability else { throw BenchError("Apple Foundation Models unavailable: \(m.availability)") }
    model = m
    let warm = LanguageModelSession(model: m, instructions: instructions)
    warm.prewarm()
    _ = try? await warm.respond(to: frame(warmText), options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 64))
    return ["availability": "\(m.availability)"]
  }

  func frame(_ c: String) -> String {
    if let p = prompt { return p.frame.replacingOccurrences(of: "{text}", with: c) }
    return wrap ? "Dictation: \(c)\nCleaned:" : c
  }

  func process(_ item: Item) async throws -> [String: Any] {
    var outs: [String] = [], errs: [String] = [], secs: [Double] = []
    let t = ContinuousClock.now
    var firstChunkS = 0.0
    let chunks = prompt?.chunk_words.flatMap { item.chunksBy[String($0)] } ?? item.chunks
    for (k, c) in chunks.enumerated() {
      // cap runaway generations: a faithful cleanup is about as long as its input
      let opts = GenerationOptions(sampling: .greedy, maximumResponseTokens: max(prompt?.min_cap ?? 64, c.split(separator: " ").count * (prompt?.cap ?? 3)))
      let session = LanguageModelSession(model: model!, instructions: instructions)
      let input = frame(c)
      let tc = ContinuousClock.now
      do {
        let r: String = try await withThrowingTaskGroup(of: String.self) { g in
          g.addTask { try await session.respond(to: input, options: opts).content }
          g.addTask { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
          let first = try await g.next()!; g.cancelAll(); return first
        }
        outs.append(r)
      } catch { outs.append(c); errs.append(error is CancellationError ? "timeout30s" : "\(error)") }
      secs.append((ContinuousClock.now - tc).seconds)
      if k == 0 { firstChunkS = (ContinuousClock.now - t).seconds }
    }
    var row: [String: Any] = ["clean": outs.joined(separator: " "), "first_chunk_s": firstChunkS, "chunks": chunks.count, "errors": errs]
    if prompt != nil { row["chunk_in"] = chunks; row["chunk_out"] = outs; row["chunk_s"] = secs }
    return row
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
