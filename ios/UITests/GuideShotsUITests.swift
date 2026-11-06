import XCTest

/// The screens the iPhone guide (docs/iphone.md) shows that no other test reaches: the app's handoff screen after
/// the keyboard's mic opened it, and the card saying which model this device gets. A synthetic clip
/// (V2T_FIXTURE_AUDIO) stands in for the microphone, so nothing records the room.
@MainActor final class GuideShotsUITests: XCTestCase {
  let app = XCUIApplication()

  /// What the keyboard's mic does with no microphone session: it opens v2t://dictate, the app starts recording and
  /// asks you to go back to your app.
  func testKeyboardLaunchShowsTheHandoffScreen() {
    continueAfterFailure = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: DictationUITests.fixture), "run ios/setup.sh to make \(DictationUITests.fixture)")
    app.launchEnvironment["V2T_FIXTURE_AUDIO"] = DictationUITests.fixture
    app.launch()
    downloadModelIfNeeded(app)  // without the model the keyboard's mic opens the download screen instead (#124)
    app.open(URL(string: "v2t://dictate")!)
    XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.buttons["Stop and stay here"].exists)
    shot("30-keyboard-handoff")
    app.buttons["Stop and stay here"].tap()
    XCTAssertTrue(app.staticTexts["Listening"].waitForNonExistence(timeout: 5))
    let stop = app.buttons["v2t.stopMic"]
    reveal(stop, in: app)
    if stop.exists { stop.tap() }  // leave no microphone session on for the next test
  }

  /// When the microphone cannot start, the keyboard's mic must not leave the handoff screen up saying the
  /// keyboard records in place: v2t shows its home screen with the mic switch off instead.
  func testHandoffClosesWhenTheMicrophoneCannotStart() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_FIXTURE_AUDIO"] = DictationUITests.fixture
    app.launchEnvironment["V2T_FIXTURE_MIC_FAILS"] = "1"
    app.launch()
    downloadModelIfNeeded(app)  // without the model the mic opens the download screen before trying the microphone
    app.open(URL(string: "v2t://dictate")!)
    XCTAssertFalse(app.staticTexts["Mic is ready"].waitForExistence(timeout: 5), "handoff stayed up with no session")
    XCTAssertFalse(app.staticTexts["Listening"].exists)
    XCTAssertTrue(app.staticTexts["v2t"].exists, app.debugDescription)
  }

  /// The "This iPhone" section: which speech model and cleanup this device gets, and why.
  func testDeviceCardNamesTheModel() {
    continueAfterFailure = false
    app.launch()
    // the card's reason line; the speech model's name also appears in the setup list above it
    let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Measured on an iPhone 16 Pro' OR label BEGINSWITH 'FluidAudio reports'")).firstMatch
    reveal(card, in: app)
    XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
    shot("31-device-card")
  }
}
