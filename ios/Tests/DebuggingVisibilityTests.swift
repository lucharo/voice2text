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

  typealias Build = DebuggingVisibility.Build

  @Test func anAppStoreBuildHidesIt() {
    #expect(Build(environment: .production, receipt: "receipt").showsDebugging == false)
  }

  @Test func aTestFlightBuildShowsIt() {
    #expect(Build(environment: .sandbox, receipt: "sandboxReceipt").showsDebugging == true)
  }

  /// Build 130 on a TestFlight install: StoreKit gave no app transaction, and Debugging was hidden.
  @Test func aTestFlightBuildShowsItWhenStoreKitGivesNoAnswer() {
    #expect(Build(environment: nil, receipt: "sandboxReceipt").showsDebugging == true)
  }

  @Test func aTestFlightBuildShowsItWhenTheBundleNamesNoReceipt() {
    #expect(Build(environment: .sandbox, receipt: nil).showsDebugging == true)
  }

  @Test func storeKitTestingInXcodeShowsIt() {
    #expect(Build(environment: .xcode, receipt: nil).showsDebugging == true)
  }

  @Test func aSandboxReceiptShowsItWhateverStoreKitSays() {
    #expect(Build(environment: .production, receipt: "sandboxReceipt").showsDebugging == true)
  }

  @Test func anAppStoreReceiptWithNoStoreKitAnswerHidesIt() {
    #expect(Build(environment: nil, receipt: "receipt").showsDebugging == false)
  }

  @Test func noSignalAtAllHidesIt() {
    #expect(Build(environment: nil, receipt: nil).showsDebugging == false)
  }

  @Test func aDebugBuildShowsItWhateverTheSignals() {
    #expect(Build(environment: .production, receipt: "receipt", debugBuild: true).showsDebugging == true)
  }

  @Test func theSimulatorShowsItWhateverTheSignals() {
    #expect(Build(environment: nil, receipt: "receipt", simulator: true).showsDebugging == true)
  }

  @Test func theLabelNamesEachKindOfBuild() {
    #expect(Build(environment: nil, receipt: "sandboxReceipt").label == "TestFlight")
    #expect(Build(environment: .sandbox, receipt: nil).label == "TestFlight")
    #expect(Build(environment: .production, receipt: "receipt").label == "App Store")
    #expect(Build(environment: .production, receipt: "receipt", debugBuild: true).label == "debug build")
    #expect(Build(environment: nil, receipt: "receipt", simulator: true).label == "Simulator")
  }

  @Test func theLabelSaysWhatEachSignalReadWhenTheyDoNotSettleIt() {
    #expect(Build(environment: nil, receipt: "receipt").label == "build type unsure (StoreKit: no answer, receipt: receipt)")
    #expect(Build(environment: .production, receipt: nil).label == "build type unsure (StoreKit: Production, receipt: none)")
    #expect(Build(environment: nil, receipt: nil).label == "build type unsure (StoreKit: no answer, receipt: none)")
  }

  @Test func theVersionLineCarriesVersionBuildNumberAndKind() {
    let info: [String: Any] = ["CFBundleShortVersionString": "1.1", "CFBundleVersion": "131"]

    let line = HomeView.versionLine(build: Build(environment: nil, receipt: "sandboxReceipt"), info: info)

    #expect(line == "v2t 1.1 (131), TestFlight")
  }

  /// The finding this guards (roborev 942): Debugging is on screen at once in a TestFlight build, so the keyboard
  /// must be allowed to record before StoreKit has answered, not only after.
  @Test @MainActor func aTestFlightReceiptApprovesTheInstallBeforeStoreKitAnswers() async {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    var approvedWhileStoreKitWasAsked: String?

    let build = await DebuggingVisibility.settle(launch: Build(environment: nil, receipt: "sandboxReceipt"),
                                                 install: testFlight, settings: settings) { launch in
      approvedWhileStoreKitWasAsked = Settings(defaults: self.defaults).debuggingInstall
      return launch
    }

    #expect(approvedWhileStoreKitWasAsked == testFlight)
    #expect(build.showsDebugging == true)
    #expect(Settings(defaults: defaults).debuggingInstall == testFlight)
    #expect(Settings(defaults: defaults).keyboardDebugLogUntil == until)
  }

  @Test @MainActor func withoutATestFlightSignalNothingIsApprovedUntilStoreKitAnswers() async {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    var approvedWhileStoreKitWasAsked: String?

    let build = await DebuggingVisibility.settle(launch: Build(environment: nil, receipt: nil),
                                                 install: testFlight, settings: settings) { launch in
      approvedWhileStoreKitWasAsked = Settings(defaults: self.defaults).debuggingInstall
      var answered = launch
      answered.environment = .sandbox
      return answered
    }

    #expect(approvedWhileStoreKitWasAsked == nil)
    #expect(build.showsDebugging == true)
    #expect(Settings(defaults: defaults).debuggingInstall == testFlight)
  }

  @Test @MainActor func anAppStoreAnswerApprovesNothingAndTurnsTheLogOff() async {
    let settings = Settings(defaults: defaults)
    settings.keyboardDebugLogUntil = until
    settings.debuggingInstall = testFlight

    let build = await DebuggingVisibility.settle(launch: Build(environment: nil, receipt: "receipt"),
                                                 install: appStore, settings: settings) { launch in
      var answered = launch
      answered.environment = .production
      return answered
    }

    #expect(build.showsDebugging == false)
    #expect(Settings(defaults: defaults).debuggingInstall == nil)
    #expect(Settings(defaults: defaults).keyboardDebugLogUntil == nil)
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
