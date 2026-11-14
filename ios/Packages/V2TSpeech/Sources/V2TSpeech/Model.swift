import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

extension SpeechEngine {
  /// The speech model a device runs. There is no catalogue: each hardware class has a single choice, grounded in
  /// what was measured on an iPhone 16 Pro (#52, #85, #67) and on FluidAudio's known limits. The v2t app's
  /// `Recommendation` adds the cleanup, the tier and the words the user sees.
  public enum Model: String, Sendable {
    case nemotron, parakeet

    /// Nemotron on Apple Intelligence-compatible devices; Parakeet on the rest, because FluidAudio reports its int8
    /// Unified encoders failing to load on the A16 chip (FluidAudio #828) and calls other earlier chips unverified.
    public static func forDevice(appleIntelligenceCompatible: Bool) -> Model {
      appleIntelligenceCompatible ? .nemotron : .parakeet
    }

    /// The model this device runs, from Apple's own Apple Intelligence eligibility check.
    public static var forThisDevice: Model { forDevice(appleIntelligenceCompatible: AppleIntelligenceStatus.current.compatible) }

    public var displayName: String {
      switch self {
      case .nemotron: "NVIDIA Nemotron-Labs Unified ASR 0.6B (int8)"
      case .parakeet: "NVIDIA Parakeet TDT 0.6B v3"
      }
    }

    public var downloadMB: Int {
      switch self {
      case .nemotron: 627  // HF FluidInference/nemotron-labs-unified-asr-0.6b-coreml@bd13ddd: int8 encoder, decoder, joint, vocab
      case .parakeet: 630  // the Mac app's listed size for the same Core ML files (v2t/backends.py)
      }
    }
  }
}

/// Apple Intelligence on this device, read from Apple's own runtime check so the model choice needs no device table.
public struct AppleIntelligenceStatus: Equatable, Sendable {
  /// Apple Intelligence's on-device model is available now.
  public var available: Bool
  /// An Apple Intelligence-compatible device (apple.com/apple-intelligence, 2026-11-02: iPhone 15 Pro and Pro Max,
  /// the iPhone 16 and 17 families, 18 Pro and Pro Max, 16e, 17e, Air and Duo; A17 Pro chips and later), whether or
  /// not the user has turned it on. SystemLanguageModel reports `.deviceNotEligible` for every other one.
  public var compatible: Bool

  public init(available: Bool, compatible: Bool) {
    self.available = available
    self.compatible = compatible
  }

  public static var current: AppleIntelligenceStatus {
    var status = AppleIntelligenceStatus(available: false, compatible: false)
    #if canImport(FoundationModels)
    switch SystemLanguageModel.default.availability {
    case .available: status = .init(available: true, compatible: true)
    case .unavailable(.deviceNotEligible): break
    case .unavailable: status.compatible = true  // not turned on, model still downloading, or language not supported
    }
    #endif
    return status
  }
}
