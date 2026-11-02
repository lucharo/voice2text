import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one speech model and cleanup this iPhone gets. There is no catalogue: each hardware class has a single
/// choice, grounded in what was measured on an iPhone 16 Pro (#52, #85, #67) and on FluidAudio's known limits.
struct Recommendation: Equatable {
  enum Speech: String { case nemotron, parakeet }
  enum Cleanup: String { case appleIntelligence, dictionaryOnly }

  let speech: Speech
  let cleanup: Cleanup
  /// Why, in a sentence the user sees.
  let reason: String
  /// Whether this iPhone model is the one the phone measurements ran on.
  let measured: Bool

  var speechName: String {
    switch speech {
    case .nemotron: "NVIDIA Nemotron-Labs Unified ASR 0.6B (int8)"
    case .parakeet: "NVIDIA Parakeet TDT 0.6B v3"
    }
  }

  var downloadMB: Int {
    switch speech {
    case .nemotron: 627  // HF FluidInference/nemotron-labs-unified-asr-0.6b-coreml@bd13ddd: int8 encoder, decoder, joint, vocab
    case .parakeet: 630  // the Mac app's listed size for the same Core ML files (v2t/backends.py)
    }
  }

  var cleanupName: String {
    switch cleanup {
    case .appleIntelligence: "Apple Intelligence (on this iPhone)"
    case .dictionaryOnly: "Your dictionary's replacements only"
    }
  }

  /// What the choice depends on, read from Apple's own runtime check so the rule needs no model table.
  struct Device: Equatable {
    /// Apple Intelligence's on-device model is available now.
    var appleIntelligence: Bool
    /// An Apple Intelligence-compatible iPhone (apple.com/apple-intelligence, 2026-11-02: iPhone 15 Pro and
    /// Pro Max, the iPhone 16, 17 and 18 families, 16e, 17e, Air and Duo; A17 Pro chips and later), whether
    /// or not the user has turned it on. SystemLanguageModel reports `.deviceNotEligible` for every other one.
    var appleIntelligenceCompatible: Bool
    /// The hardware identifier (utsname machine), e.g. "iPhone17,1".
    var model: String = ""
    /// Every phone measurement so far (#52, #67, #85) ran on one iPhone 16 Pro, which `xcrun devicectl list
    /// devices` on the bench Mac reports as iPhone17,1.
    var isMeasuredModel: Bool { model == "iPhone17,1" }
  }

  static func choose(for d: Device) -> Recommendation {
    if d.appleIntelligenceCompatible {
      return Recommendation(
        speech: .nemotron,
        cleanup: d.appleIntelligence ? .appleIntelligence : .dictionaryOnly,
        reason: d.appleIntelligence
          ? "Measured on an iPhone 16 Pro: the fewest mistakes of the phone models tested (1.7% of words in English, 3.4% in Spanish), text ready 0.1 s after you stop. Apple Intelligence tidies punctuation without a download."
          : "Measured on an iPhone 16 Pro: the fewest mistakes of the phone models tested. Turn on Apple Intelligence in Settings to add cleanup.",
        measured: d.isMeasuredModel)
    }
    return Recommendation(
      speech: .parakeet, cleanup: .dictionaryOnly,
      reason: "Nemotron's compact build fails to load on some earlier iPhone chips (A16 confirmed, FluidAudio #828), so this iPhone gets Parakeet, which got 1.9% of English words wrong on an iPhone 16 Pro. Neither model has been tested on this iPhone.",
      measured: false)
  }

  @MainActor static var current: Recommendation { choose(for: .current) }
}

extension Recommendation.Device {
  @MainActor static var current: Recommendation.Device {
    var available = false, compatible = false
    #if canImport(FoundationModels)
    switch SystemLanguageModel.default.availability {
    case .available: available = true; compatible = true
    case .unavailable(.deviceNotEligible): break
    case .unavailable: compatible = true  // not turned on, model still downloading, or language not supported
    }
    #endif
    var info = utsname()
    uname(&info)
    let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return .init(appleIntelligence: available, appleIntelligenceCompatible: compatible, model: model)
  }
}
