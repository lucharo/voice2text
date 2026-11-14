import Testing
import V2TSpeech

/// The model a device runs, as another app asks for it (the v2t app's RecommendationTests cover its own wording).
struct ModelChoiceTests {
  @Test func appleIntelligenceCompatibleDevicesGetNemotron() {
    let model = SpeechEngine.Model.forDevice(appleIntelligenceCompatible: true)

    #expect(model == .nemotron)
  }

  /// FluidAudio #828: the int8 Unified encoders fail to load on the A16, so earlier chips get Parakeet.
  @Test func otherDevicesGetParakeet() {
    let model = SpeechEngine.Model.forDevice(appleIntelligenceCompatible: false)

    #expect(model == .parakeet)
  }
}
