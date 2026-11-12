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

  @Test func accuracyCopyNamesEveryMeasuredSet() {
    for d in [Recommendation.Device(appleIntelligence: true, appleIntelligenceCompatible: true),
              .init(appleIntelligence: false, appleIntelligenceCompatible: true),
              .init(appleIntelligence: false, appleIntelligenceCompatible: false)] {
      let reason = Recommendation.choose(for: d).reason
      #expect(["clear English", "harder English", "Spanish"].allSatisfy(reason.contains), "\(reason)")
    }
  }

  @Test func cleanupLineFollowsAppleIntelligenceAvailability() {
    let on = Recommendation.choose(for: .init(appleIntelligence: true, appleIntelligenceCompatible: true))
    let off = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: true))
    #expect(on.cleanupName.contains("Apple Intelligence") && on.reason.contains("Apple Intelligence is on"))
    #expect(!off.cleanupName.contains("Apple Intelligence") && off.reason.contains("Apple Intelligence is off"))
  }

  /// A phone that can never run Apple Intelligence (an iPhone 12 Pro) is not told it is merely off.
  @Test func greyedCleanupSaysWhyForADeviceThatCannotRunAppleIntelligence() {
    let r = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: false))

    #expect(r.cleanupUnavailable == "Unavailable: this iPhone can't run Apple Intelligence, so you get the words as heard, plus your dictionary's replacements.")
  }

  @Test func greyedCleanupSaysAppleIntelligenceIsOffWhereItCouldBeTurnedOn() {
    let r = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: true))

    #expect(r.cleanupUnavailable == "Unavailable: Apple Intelligence is off or not ready on this iPhone, so you get the words as heard, plus your dictionary's replacements.")
  }

  @Test func greyedCleanupNamesTheIPad() {
    let r = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: false, deviceName: "iPad"))

    #expect(r.cleanupUnavailable == "Unavailable: this iPad can't run Apple Intelligence, so you get the words as heard, plus your dictionary's replacements.")
  }

  @Test func otherPhonesGetParakeetBecauseOfTheA16LoadFailure() {
    let r = Recommendation.choose(for: .init(appleIntelligence: false, appleIntelligenceCompatible: false))
    #expect([r.speech.rawValue, r.cleanup.rawValue] == ["parakeet", "dictionaryOnly"])
    #expect(!r.measured)
    #expect(r.reason.contains("#828"))
  }
}
