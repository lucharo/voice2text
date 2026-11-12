import XCTest

/// The companion app's own screens: the dictionary editor keeps what you add across a relaunch, and the
/// cleanup switch drives the recommendation card. Needs the speech model already on the Simulator only for
/// the ready row; nothing here records audio.
@MainActor final class AppUITests: XCTestCase {
  let app = XCUIApplication.v2t()

  func open(_ label: String) {
    let b = app.buttons[label]
    reveal(b, in: app)
    b.tap()
  }

  func testDictionaryEditorKeepsEntriesAcrossARelaunch() {
    continueAfterFailure = false
    app.launch()
    open("Dictionary")
    let term = "Fluide\(Int.random(in: 1000...9999))"  // unique per run, so a rerun never meets its own entry
    typeWithAppleKeyboard(term, into: app.textFields["v2t.dict.term"], app: app)
    app.buttons["v2t.dict.addTerm"].tap()
    XCTAssertTrue(app.staticTexts[term].waitForExistence(timeout: 5), app.debugDescription)
    shot("20-dictionary-editor")

    app.terminate()
    app.launch()
    open("Dictionary")
    XCTAssertTrue(app.staticTexts[term].waitForExistence(timeout: 5), "term lost on relaunch")

    // swipe to delete, and the deletion sticks too
    app.staticTexts[term].swipeLeft()
    app.buttons["Delete"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts[term].waitForNonExistence(timeout: 5))
    app.terminate()
    app.launch()
    open("Dictionary")
    XCTAssertFalse(app.staticTexts[term].waitForExistence(timeout: 2), "deleted term came back")
  }

  /// The keyboard's settings and, in a test build, Debugging are sections of the first page, with nothing to open.
  func testKeyboardAndDebuggingAreSectionsOfTheHomePage() {
    continueAfterFailure = false
    app.launch()
    XCTAssertFalse(app.buttons["Languages and typing"].exists)
    let skinTone = app.buttons["settings.skinTone"].firstMatch
    reveal(skinTone, in: app)
    XCTAssertTrue(skinTone.exists, app.debugDescription)
    XCTAssertTrue(app.buttons["Layout"].firstMatch.exists || app.staticTexts["Layout"].exists, app.debugDescription)
    shot("25-home-keyboard")
    let log = app.switches["settings.debugLog"].firstMatch
    reveal(log, in: app)
    XCTAssertTrue(log.exists, "no Debugging section on the home page of a test build")
    XCTAssertTrue(app.staticTexts["Debugging"].exists || app.staticTexts["DEBUGGING"].exists, app.debugDescription)
    XCTAssertTrue(app.buttons["settings.debugLogExport"].exists)
    let exercise = app.buttons["settings.typingExercise"]
    reveal(exercise, in: app)
    XCTAssertTrue(exercise.exists)
    XCTAssertTrue(app.navigationBars["v2t"].exists, "Debugging opened a screen of its own")
    shot("26-home-debugging")
  }

  func testCleanupSwitchDrivesTheRecommendationCard() {
    continueAfterFailure = false
    app.launch()
    shot("21-home-top")
    let cleanup = app.switches["v2t.cleanup"].firstMatch
    reveal(cleanup, in: app)
    guard cleanup.isEnabled else {
      let none = app.staticTexts["Cleanup: none, your dictionary's replacements only"]
      reveal(none, in: app)
      XCTAssertTrue(none.exists)
      shot("22-cleanup-unavailable")
      return
    }
    if (cleanup.value as? String) != "1" { cleanup.switches.firstMatch.tap() }
    let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cleanup: Apple Intelligence, on this'")).firstMatch
    reveal(card, in: app)
    XCTAssertTrue(card.exists)
    shot("22-cleanup-on")

    // the Keyboard section sits between the switch and the card: back up to the switch, down to the card
    flip(cleanup)
    let off = app.staticTexts["Cleanup: off (turned off above)"]
    reveal(off, in: app)
    XCTAssertTrue(off.waitForExistence(timeout: 3))
    shot("23-cleanup-off")
    flip(cleanup)
    reveal(card, in: app)
    XCTAssertTrue(card.waitForExistence(timeout: 3))
  }

  /// Scrolls back up to `toggle` and flips it.
  func flip(_ toggle: XCUIElement) {
    for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeDown(velocity: .slow) }
    toggle.switches.firstMatch.tap()
  }

  func testACachedModelNeverShowsAsDownloading() {
    let ready = modelReady(app)
    app.launch()
    downloadModelIfNeeded(app)  // a fresh Simulator has no model until Download is tapped
    app.terminate()
    app.launch()
    // sample the model row from launch until ready: it may say Preparing, never Downloading
    let deadline = Date().addingTimeInterval(300)
    var sawDownloading = false, first = true
    while !ready.exists, Date() < deadline {
      if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading'")).firstMatch.exists { sawDownloading = true }
      if first { shot("24-cached-model-loading"); first = false }
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    XCTAssertTrue(ready.exists, "model never became ready")
    XCTAssertFalse(sawDownloading, "a cached model showed as downloading")
  }
}
