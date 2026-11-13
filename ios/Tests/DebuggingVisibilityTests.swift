import Foundation
import StoreKit
import Testing
@testable import V2T

struct DebuggingVisibilityTests {
  let defaults = UserDefaults(suiteName: "v2t-debugging-\(UUID().uuidString)")!
  let until = Date(timeIntervalSince1970: 2_000_000_000)
  let now = Date(timeIntervalSince1970: 1_900_000_000)
  let testFlight = "/var/containers/Bundle/Application/1A2B3C4D-0000-4000-8000-000000000001/V2T.app"
  let appStore = "/var/containers/Bundle/Application/5E6F7A8B-0000-4000-8000-000000000002/V2T.app"

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

  @Test func hidingItTurnsTheDebugLogOffForEveryInstall() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    settings.debuggingInstall = testFlight

    DebuggingVisibility.apply(shows: false, install: appStore, to: settings)

    let read = Settings(defaults: defaults)
    #expect(read.keyboardDebugLogUntil == nil)
    #expect(read.debuggingInstall == nil)
  }

  @Test func showingItKeepsTheLogAndApprovesThisInstall() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until

    DebuggingVisibility.apply(shows: true, install: testFlight, to: settings)

    let read = Settings(defaults: defaults)
    #expect(read.keyboardDebugLogUntil == until)
    #expect(read.debuggingInstall == testFlight)
  }

  @Test func theAppAndItsKeyboardNameTheSameInstall() {
    let app = URL(fileURLWithPath: testFlight)
    let keyboard = app.appending(path: "PlugIns/V2TKeyboard.appex")

    let fromApp = DebuggingVisibility.install(of: app)

    #expect(fromApp != nil)
    #expect(fromApp?.hasSuffix("/1A2B3C4D-0000-4000-8000-000000000001/V2T.app") == true)
    #expect(DebuggingVisibility.install(of: keyboard) == fromApp)
    #expect(DebuggingVisibility.install(of: URL(fileURLWithPath: appStore)) != fromApp)
  }

  @Test func aBundleOutsideAnAppIsNoInstall() {
    #expect(DebuggingVisibility.install(of: URL(fileURLWithPath: "/tmp/V2TKeyboard.appex")) == nil)
  }

  /// The finding this guards (roborev 924): the App Store build replaced a TestFlight build whose log was on, and
  /// the keyboard opens before v2t does.
  @Test func theKeyboardDoesNotLogForAnInstallTheAppHasNotApproved() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    settings.debuggingInstall = testFlight

    let result = DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: appStore, shownByBuild: false, now: now)

    #expect(result == nil)
  }

  @Test func theKeyboardLogsForTheInstallTheAppApproved() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    settings.debuggingInstall = testFlight

    let result = DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: testFlight, shownByBuild: false, now: now)

    #expect(result == until)
  }

  @Test func theKeyboardDoesNotLogBeforeTheAppHasDecided() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until

    let result = DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: testFlight, shownByBuild: false, now: now)

    #expect(result == nil)
  }

  @Test func theKeyboardDoesNotLogWhenItCannotNameItsInstall() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    settings.debuggingInstall = testFlight

    let result = DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: nil, shownByBuild: false, now: now)

    #expect(result == nil)
  }

  @Test func aDebugOrSimulatorKeyboardLogsWithoutTheAppsRecord() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until

    let result = DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: nil, shownByBuild: true, now: now)

    #expect(result == until)
  }

  @Test func thePastDeadlineStillStopsTheLog() {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    settings.debuggingInstall = testFlight

    let late = Date(timeIntervalSince1970: 2_000_000_001)

    #expect(DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: testFlight, shownByBuild: false, now: late) == nil)
    #expect(DebuggingVisibility.keyboardLogUntil(settings: settings, thisInstall: nil, shownByBuild: true, now: late) == nil)
  }
}
