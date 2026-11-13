import XCTest

/// About v2t: it opens by itself on the first launch after install, Continue leads to the setup list, and it never
/// opens by itself again; its row on the home screen opens it any time.
@MainActor final class AboutUITests: XCTestCase {
  let app = XCUIApplication()
  var headline: XCUIElement { app.staticTexts["v2t.about.headline"] }

  func testOpensOnTheFirstLaunchOnly() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_FIRST_LAUNCH"] = "1"  // as just installed
    app.launch()
    XCTAssertTrue(headline.waitForExistence(timeout: 10), app.debugDescription)
    shot("05-about-first-launch")

    app.buttons["v2t.about.continue"].tap()

    XCTAssertTrue(headline.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.textFields["v2t.try"].waitForExistence(timeout: 5), "Continue did not lead to the setup list")
    app.terminate()
    app.launchEnvironment.removeValue(forKey: "V2T_FIRST_LAUNCH")  // the second launch keeps what the first stored
    app.launch()
    XCTAssertTrue(app.textFields["v2t.try"].waitForExistence(timeout: 10))
    XCTAssertFalse(headline.waitForExistence(timeout: 3), "About v2t opened again on the second launch")
  }

  func testReopensFromItsRow() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_FIRST_LAUNCH"] = "0"
    app.launch()
    let row = app.buttons["v2t.about.open"]
    reveal(row, in: app)

    row.tap()

    XCTAssertTrue(headline.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.buttons["v2t.about.continue"].exists, "the row's page has Back, not Continue")
    shot("06-about-from-row")
  }

  /// The line under the About v2t row: which version, which build, and what kind of build the app takes itself for.
  func testTheHomePageEndsWithTheVersionAndTheKindOfBuild() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_FIRST_LAUNCH"] = "0"
    app.launch()
    let line = app.staticTexts["v2t.version"]
    reveal(line, in: app)

    let label = line.label

    XCTAssertTrue(label.hasPrefix("v2t "), label)
    // UI tests run a debug build in the Simulator; either name is this build told apart from the App Store's
    XCTAssertTrue(label.hasSuffix(", debug build") || label.hasSuffix(", Simulator"), label)
    XCTAssertTrue(app.switches["settings.debugLog"].exists, "such a build shows Debugging: \(app.debugDescription)")
    shot("07-home-version-line")
  }
}
