import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one speech model and cleanup this iPhone or iPad gets. There is no catalogue: each hardware class has a single
/// choice, grounded in what was measured on an iPhone 16 Pro (#52, #85, #67) and on FluidAudio's known limits.
struct Recommendation: Equatable {
  enum Speech: String { case nemotron, parakeet }
  enum Cleanup: String { case appleIntelligence, dictionaryOnly }

  let speech: Speech
  let cleanup: Cleanup
  /// Why, in a sentence the user sees.
  let reason: String
  /// Whether this model of iPhone is the one the phone measurements ran on.
  let measured: Bool
  /// "iPhone" or "iPad", for the words the user sees.
  var deviceName = "iPhone"
  /// Whether this device can run Apple Intelligence at all, turned on or not: one that never can must not be
  /// told to turn it on.
  var appleIntelligenceCompatible = true

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
    case .appleIntelligence: "Cleanup: Apple Intelligence, on this \(deviceName)"
    case .dictionaryOnly: "Cleanup: none, your dictionary's replacements only"
    }
  }

  /// Why the cleanup switch is greyed out, and what the user gets instead. Without cleanup the dictionary's
  /// replacements still apply; its exact spellings are only used by cleanup.
  var cleanupUnavailable: String {
    appleIntelligenceCompatible
      ? "Unavailable: Apple Intelligence is off or not ready on this \(deviceName), so you get the words as heard, plus your dictionary's replacements."
      : "Unavailable: this \(deviceName) can't run Apple Intelligence, so you get the words as heard, plus your dictionary's replacements."
  }

  /// What the choice depends on, read from Apple's own runtime check so the rule needs no model table.
  struct Device: Equatable {
    /// Apple Intelligence's on-device model is available now.
    var appleIntelligence: Bool
    /// An Apple Intelligence-compatible iPhone (apple.com/apple-intelligence, 2026-11-02: iPhone 15 Pro and
    /// Pro Max, the iPhone 16 and 17 families, 18 Pro and Pro Max, 16e, 17e, Air and Duo; A17 Pro chips and later), whether
    /// or not the user has turned it on. SystemLanguageModel reports `.deviceNotEligible` for every other one.
    var appleIntelligenceCompatible: Bool
    /// The hardware identifier (utsname machine), e.g. "iPhone17,1".
    var model: String = ""
    /// "iPhone" or "iPad". iPads take the same rule: Apple Intelligence-compatible iPads (M1 and later, A17 Pro)
    /// get Nemotron, the rest Parakeet; no iPad has been measured.
    var deviceName = "iPhone"
    /// Every phone measurement so far (#52, #67, #85) ran on one iPhone 16 Pro, which `xcrun devicectl list
    /// devices` on the bench Mac reports as iPhone17,1.
    var isMeasuredModel: Bool { model == "iPhone17,1" }
  }

  // Words wrong on the iPhone 16 Pro bench (#85, 150 clips per set): LibriSpeech clean ("clear English"),
  // LibriSpeech other ("harder English") and FLEURS Spanish.
  static func choose(for d: Device) -> Recommendation {
    var r = chooseModel(for: d)
    r.deviceName = d.deviceName
    r.appleIntelligenceCompatible = d.appleIntelligenceCompatible
    return r
  }

  private static func chooseModel(for d: Device) -> Recommendation {
    let device = d.deviceName
    if d.appleIntelligenceCompatible {
      let measured = "Measured on an iPhone 16 Pro: the fewest mistakes of the phone models tested (1.7% of words wrong on clear English, 3.4% on harder English, 3.4% on Spanish), text ready about 0.1 s after you stop, or about 1 to 1.5 s with Apple Intelligence cleanup."
      return Recommendation(
        speech: .nemotron,
        cleanup: d.appleIntelligence ? .appleIntelligence : .dictionaryOnly,
        reason: measured + (d.appleIntelligence
          ? " Apple Intelligence is on, so it tidies punctuation on the \(device) without a download."
          : " Apple Intelligence is off or not ready, so there is no cleanup: turn it on in Settings › Apple Intelligence & Siri."),
        measured: d.isMeasuredModel)
    }
    return Recommendation(
      speech: .parakeet, cleanup: .dictionaryOnly,
      reason: "FluidAudio reports its int8 Unified encoders failing to load on the A16 chip (FluidAudio #828, the Parakeet Unified sibling of Nemotron) and calls other earlier chips unverified, so this \(device) gets Parakeet, which on an iPhone 16 Pro got 1.9% of words wrong on clear English, 3.9% on harder English and 4.1% on Spanish. Neither model has been tested on this \(device).",
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
    return .init(appleIntelligence: available, appleIntelligenceCompatible: compatible, model: model,
                 deviceName: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
  }
}
