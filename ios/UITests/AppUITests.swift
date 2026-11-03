import XCTest

/// The companion app's own screens: the dictionary editor keeps what you add across a relaunch, and the
/// cleanup switch drives the recommendation card. Needs the speech model already on the Simulator only for
/// the ready row; nothing here records audio.
@MainActor final class AppUITests: XCTestCase {
  let app = XCUIApplication()

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

  func testCleanupSwitchDrivesTheRecommendationCard() {
    continueAfterFailure = false
    app.launch()
    shot("21-home-top")
    let cleanup = app.switches["v2t.cleanup"].firstMatch
    reveal(cleanup, in: app)
    guard cleanup.isEnabled else {
      XCTAssertTrue(app.staticTexts["Cleanup: none, your dictionary's replacements only"].exists)
      shot("22-cleanup-unavailable")
      return
    }
    if (cleanup.value as? String) != "1" { cleanup.switches.firstMatch.tap() }
    let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cleanup: Apple Intelligence, on this'")).firstMatch
    reveal(card, in: app)
    XCTAssertTrue(card.exists)
    shot("22-cleanup-on")

    cleanup.switches.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Cleanup: off (turned off above)"].waitForExistence(timeout: 3))
    shot("23-cleanup-off")
    cleanup.switches.firstMatch.tap()
    XCTAssertTrue(card.waitForExistence(timeout: 3))
  }

  func testACachedModelNeverShowsAsDownloading() {
    let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch
    app.launch()  // the first launch on a fresh Simulator downloads the model; wait for that
    XCTAssertTrue(ready.waitForExistence(timeout: 1200), "model never became ready")
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
