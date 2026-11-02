import Testing
@testable import V2T

struct RecommendationTests {
  @Test func appleIntelligencePhonesGetNemotronAndAppleCleanup() {
    let r = Recommendation.choose(for: .init(appleIntelligence: true, appleIntelligenceCompatible: true, model: "iPhone17,1"))
    #expect([r.speech.rawValue, r.cleanup.rawValue] == ["nemotron", "appleIntelligence"])
    #expect(r.measured)
  }

  @Test func onlyTheMeasuredIPhone16ProCountsAsMeasured() {
    let r = Recommendation.choose(for: .init(appleIntelligence: true, appleIntelligenceCompatible: true, model: "iPhone16,1"))
    #expect(r.speech.rawValue == "nemotron")
    #expect(!r.measured)
  }

  @Test func appleIntelligenceTurnedOffKeepsNemotronWithoutCleanup() {
    let r = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: true))
    #expect([r.speech.rawValue, r.cleanup.rawValue] == ["nemotron", "dictionaryOnly"])
  }

  @Test func otherPhonesGetParakeetBecauseOfTheA16LoadFailure() {
    let r = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: false))
    #expect([r.speech.rawValue, r.cleanup.rawValue] == ["parakeet", "dictionaryOnly"])
    #expect(!r.measured)
    #expect(r.reason.contains("#828"))
  }
}
