import Foundation
import UIKit
import V2TSpeech

/// The one speech model and cleanup this iPhone or iPad gets. There is no catalogue: each hardware class has a single
/// choice, grounded in what was measured on an iPhone 16 Pro (#52, #85, #67) and on FluidAudio's known limits.
struct Recommendation: Equatable {
  /// The model itself is chosen in V2TSpeech, which other apps share.
  typealias Speech = SpeechEngine.Model
  enum Cleanup: String { case appleIntelligence, dictionaryOnly }
  /// What dictation this device gets (the owner's tiers, 2026-11-12: "Tiers now, measure next").
  enum Tier: String {
    /// Apple Intelligence-compatible: transcription and cleanup.
    case full
    /// Transcription only, on a chip no one has tested v2t on (A15, A16, and any device not listed below).
    case untested
    /// A13 and A14 devices: dictation is off until one has passed a test run; typing still works.
    case notSupported
  }

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
  var tier = Tier.full

  var speechName: String { speech.displayName }

  var downloadMB: Int { speech.downloadMB }

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

  /// Shown instead of the model download on a device whose tier is not supported, and on the screen the
  /// keyboard's mic opens there.
  var notSupportedMessage: String { "Dictation isn't supported on this \(deviceName) yet. The keyboard still works for typing." }
  var notSupportedReason: String { "These \(deviceName) models have not passed a test run." }
  /// Under the model row on a device in the untested tier; nothing is blocked.
  var untestedLine: String { "Not yet tested on this \(deviceName) model." }

  /// What the choice depends on, read from Apple's own runtime check so the rule needs no model table.
  struct Device: Equatable {
    /// Apple Intelligence's on-device model is available now.
    var appleIntelligence: Bool
    /// An Apple Intelligence-compatible device, whether or not the user has turned it on
    /// (`AppleIntelligenceStatus.compatible` lists them).
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
    r.tier = tier(for: d)
    return r
  }

  /// Apple Intelligence eligibility decides the top tier, as it decides the model; a hardware identifier in
  /// `notYetSupported` the bottom one. Anything else, a future identifier or the Simulator included, is untested
  /// rather than blocked.
  static func tier(for d: Device) -> Tier {
    if d.appleIntelligenceCompatible { return .full }
    return notYetSupported.contains(d.model) ? .notSupported : .untested
  }

  /// A13 and A14 iPhones and iPadOS 26 iPads with A12 to A14 chips, by hardware identifier (utsname machine).
  /// Identifiers and names: Apple's own device table in Xcode 26.6 (17F113),
  /// Platforms/iPhoneOS.platform/usr/standalone/device_traits.db, Devices.ProductType and ProductDescription.
  /// iPhones by name, as the owner listed them. iPads: the iPadOS 26 list
  /// (https://support.apple.com/guide/ipad/ipad-models-compatible-with-ipados-26-ipad213a25b2/26/ipados/26), with
  /// each model's chip from https://www.apple.com/ipad/compare/ (checked 2026-11-12).
  static let notYetSupported: Set<String> = [
    "iPhone12,1",  // iPhone 11 (A13)
    "iPhone12,3",  // iPhone 11 Pro (A13)
    "iPhone12,5",  // iPhone 11 Pro Max (A13)
    "iPhone12,8",  // iPhone SE (2nd generation) (A13)
    "iPhone13,1",  // iPhone 12 mini (A14)
    "iPhone13,2",  // iPhone 12 (A14)
    "iPhone13,3",  // iPhone 12 Pro (A14)
    "iPhone13,4",  // iPhone 12 Pro Max (A14)
    "iPad11,1", "iPad11,2",  // iPad mini (5th generation) (A12 Bionic)
    "iPad11,3", "iPad11,4",  // iPad Air (3rd generation) (A12 Bionic)
    "iPad11,6", "iPad11,7",  // iPad (8th generation) (A12 Bionic)
    "iPad12,1", "iPad12,2",  // iPad (9th generation) (A13 Bionic)
    "iPad13,1", "iPad13,2",  // iPad Air (4th generation) (A14 Bionic)
    "iPad13,18", "iPad13,19",  // iPad (10th generation) (A14 Bionic)
    "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4",  // iPad Pro (11-inch) (1st generation) (A12X Bionic)
    "iPad8,9", "iPad8,10",  // iPad Pro (11-inch) (2nd generation) (A12Z Bionic)
    "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8",  // iPad Pro (12.9-inch) (3rd generation) (A12X Bionic)
    "iPad8,11", "iPad8,12",  // iPad Pro (12.9-inch) (4th generation) (A12Z Bionic)
  ]

  private static func chooseModel(for d: Device) -> Recommendation {
    let device = d.deviceName
    let speech = Speech.forDevice(appleIntelligenceCompatible: d.appleIntelligenceCompatible)
    if d.appleIntelligenceCompatible {
      let measured = "Measured on an iPhone 16 Pro: the fewest mistakes of the phone models tested (1.7% of words wrong on clear English, 3.4% on harder English, 3.4% on Spanish), text ready about 0.1 s after you stop, or about 1 to 1.5 s with Apple Intelligence cleanup."
      return Recommendation(
        speech: speech,
        cleanup: d.appleIntelligence ? .appleIntelligence : .dictionaryOnly,
        reason: measured + (d.appleIntelligence
          ? " Apple Intelligence is on, so it tidies punctuation on the \(device) without a download."
          : " Apple Intelligence is off or not ready, so there is no cleanup: turn it on in Settings › Apple Intelligence & Siri."),
        measured: d.isMeasuredModel)
    }
    if tier(for: d) == .notSupported {
      // the model this device would get, kept so storage can still name and delete one downloaded before
      return Recommendation(
        speech: speech, cleanup: .dictionaryOnly,
        reason: "Dictation isn't supported on this \(device) yet: these \(device) models have not passed a test run. The keyboard still works for typing.",
        measured: false)
    }
    return Recommendation(
      speech: speech, cleanup: .dictionaryOnly,
      reason: "FluidAudio reports its int8 Unified encoders failing to load on the A16 chip (FluidAudio #828, the Parakeet Unified sibling of Nemotron) and calls other earlier chips unverified, so this \(device) gets Parakeet, which on an iPhone 16 Pro got 1.9% of words wrong on clear English, 3.9% on harder English and 4.1% on Spanish. Neither model has been tested on this \(device).",
      measured: false)
  }

  @MainActor static var current: Recommendation { choose(for: .current) }
}

extension Recommendation.Device {
  @MainActor static var current: Recommendation.Device {
    let ai = AppleIntelligenceStatus.current
    var info = utsname()
    uname(&info)
    let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return .init(appleIntelligence: ai.available, appleIntelligenceCompatible: ai.compatible, model: model,
                 deviceName: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
  }
}
