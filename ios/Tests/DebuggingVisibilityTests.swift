import Foundation
import StoreKit
import Testing
@testable import V2T

struct DebuggingVisibilityTests {
  let defaults = UserDefaults(suiteName: "v2t-debugging-\(UUID().uuidString)")!

  @Test func appStoreBuildHidesIt() {
    #expect(DebuggingVisibility.shows(environment: .production, debugBuild: false, simulator: false) == false)
  }

  @Test func testFlightBuildShowsIt() {
    #expect(DebuggingVisibility.shows(environment: .sandbox, debugBuild: false, simulator: false) == true)
  }

  @Test func storeKitTestingInXcodeShowsIt() {
    #expect(DebuggingVisibility.shows(environment: .xcode, debugBuild: false, simulator: false) == true)
  }

  @Test func anUnreadableEnvironmentHidesIt() {
    #expect(DebuggingVisibility.shows(environment: nil, debugBuild: false, simulator: false) == false)
  }

  @Test func aDebugBuildShowsItWhateverTheEnvironment() {
    #expect(DebuggingVisibility.shows(environment: .production, debugBuild: true, simulator: false) == true)
  }

  @Test func theSimulatorShowsItWhateverTheEnvironment() {
    #expect(DebuggingVisibility.shows(environment: nil, debugBuild: false, simulator: true) == true)
  }

  @Test func hidingItTurnsTheDebugLogOff() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = Date(timeIntervalSince1970: 2_000_000_000)

    DebuggingVisibility.apply(shows: false, to: settings)

    #expect(Settings(defaults: defaults).keyboardDebugLogUntil == nil)
  }

  @Test func showingItLeavesTheDebugLogAsItWas() {
    let settings = Settings(defaults: defaults)
    let until = Date(timeIntervalSince1970: 2_000_000_000)
    settings.keyboardDebugLogUntil = until

    DebuggingVisibility.apply(shows: true, to: settings)

    #expect(Settings(defaults: defaults).keyboardDebugLogUntil == until)
  }
}
