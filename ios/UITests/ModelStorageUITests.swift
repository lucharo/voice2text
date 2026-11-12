import XCTest

/// #124: the speech model downloads only when asked, can be deleted (with the mic session on), and the keyboard's
/// mic then opens the app's download screen instead of recording. The Storage section says what is kept.
@MainActor final class ModelStorageUITests: XCTestCase {
  func testTheModelDownloadsOnlyWhenAskedAndCanBeDeleted() throws {
    continueAfterFailure = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: DictationUITests.fixture), "run ios/setup.sh to make \(DictationUITests.fixture)")
    let app = XCUIApplication.v2t()
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    app.launchEnvironment["V2T_FIXTURE_AUDIO"] = DictationUITests.fixture
    app.launch()
    if !app.staticTexts["Done: the v2t keyboard is on."].waitForExistence(timeout: 5) {
      app.terminate()
      allowFullAccess()
      app.launch()
    }
    downloadModelIfNeeded(app)

    // the mic session on, as for a user who dictates from other apps
    let warm = app.switches["v2t.warm"].firstMatch
    reveal(warm, in: app)
    func isOn() -> Bool { "\(warm.value ?? "")" == "1" }
    for _ in 0..<3 where !isOn() {
      warm.switches.firstMatch.exists ? warm.switches.firstMatch.tap() : warm.tap()
      let until = Date().addingTimeInterval(3)
      while !isOn(), Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    }
    XCTAssertTrue(isOn(), "mic-ready switch never turned on")

    // Storage: the model's size, and that History keeps text only
    let delete = app.buttons["v2t.storage.deleteModel"]
    reveal(delete, in: app)
    XCTAssertTrue(delete.waitForExistence(timeout: 5) && delete.isEnabled, app.debugDescription)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Text only. Audio is never saved.'")).firstMatch.exists)
    // the card above Storage links to how the model was chosen (one model, no choice to make)
    XCTAssertTrue(app.descendants(matching: .any)["v2t.model.evaluation"].exists, app.debugDescription)
    shot("30-storage-with-model")
    let clear = app.buttons["v2t.storage.clearHistory"]
    if clear.isEnabled {
      clear.tap()
      app.buttons["Delete all"].firstMatch.tap()
      XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Dictations, None'")).firstMatch.waitForExistence(timeout: 5))
    }

    delete.tap()
    let confirm = app.buttons["Delete"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Speech model, Not downloaded'")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(delete.isEnabled)
    shot("31-storage-model-deleted")

    // the keyboard's mic, with the session still on, opens the download screen rather than recording
    for _ in 0..<6 where !app.textFields["v2t.try"].isHittable { app.swipeDown(velocity: .slow) }
    let field = app.textFields["v2t.try"]
    sleep(1)
    let key = { (id: String) in app.descendants(matching: .any)["key.\(id)"] }
    for _ in 0..<2 where !key("letters-q").exists {
      field.tap()
      for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 10) {
        if app.buttons["Next keyboard"].exists { app.buttons["Next keyboard"].tap() }
      }
    }
    XCTAssertTrue(key("mic").waitForExistence(timeout: 10), app.debugDescription)
    key("mic").tap()
    XCTAssertTrue(app.staticTexts["Download the speech model"].waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertFalse(app.buttons["v2t.recording.done"].exists, "the keyboard started recording without a model")
    shot("32-mic-without-model")
    app.buttons["Close"].tap()

    // a relaunch starts no download by itself
    app.terminate()
    app.launch()
    let download = app.buttons["v2t.model.download"]
    XCTAssertTrue(download.waitForExistence(timeout: 30), app.debugDescription)
    RunLoop.current.run(until: Date().addingTimeInterval(5))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading'")).firstMatch.exists, "the model started downloading by itself")
    XCTAssertTrue(download.exists)
    shot("33-launch-without-model")

    // Download brings it back (and leaves it for the other tests)
    download.tap()
    XCTAssertTrue(modelReady(app).waitForExistence(timeout: 1200), "model never became ready")
    shot("34-model-downloaded")
  }
}
