import XCTest

/// The keyboard debug log (#162) end to end: the app's switch turns it on, the keyboard shows its red dot and
/// records typing, a swipe, a correction and its revert and a suggestion tap, and the app then shows a log to
/// export. The log it leaves in the Simulator's App Group is what `ios/tools/kb_log_report.py` was tried on.
@MainActor final class DebugLogUITests: XCTestCase {
  let app = XCUIApplication()

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }
  var field: XCUIElement { app.textFields["v2t.try"] }
  var text: String { field.value as? String ?? "" }
  var logSwitch: XCUIElement { app.switches["settings.debugLog"] }

  func launch() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    app.launchEnvironment["V2T_RESET_DICTIONARY"] = "1"
    app.launchEnvironment["V2T_RESET_KEYBOARD_LOG"] = "1"
    app.launch()
    // a fresh Simulator clone has not added the keyboard yet: add it once, as KeyboardUITests does
    if !app.staticTexts["Done: the v2t keyboard is on."].waitForExistence(timeout: 5) {
      app.terminate()
      allowFullAccess()
      app.launch()
    }
    _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch.waitForExistence(timeout: 120)
  }

  func openKeyboardSettings() {
    let link = app.buttons["Languages and typing"]
    reveal(link, in: app)
    link.tap()
    reveal(logSwitch, in: app)
    XCTAssertTrue(logSwitch.waitForExistence(timeout: 5), app.debugDescription)
  }

  func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

  func flip(_ s: XCUIElement) { s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap() }

  func waitForText(_ want: String) {
    let settled = Date().addingTimeInterval(3)
    while text != want, Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(text, want)
  }

  func testSwitchDotAndRecording() {
    launch()
    openKeyboardSettings()
    XCTAssertEqual(logSwitch.value as? String, "0", "off by default")
    XCTAssertTrue(app.staticTexts["Empty"].exists)
    flip(logSwitch)
    XCTAssertEqual(logSwitch.value as? String, "1")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On until'")).firstMatch.exists)
    shot("20-debug-log-switch-on")
    back()

    // the keyboard: its dot shows, and what is typed is recorded
    for _ in 0..<6 where !(field.exists && field.isHittable) { app.swipeDown(velocity: .slow) }
    field.tap()
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.descendants(matching: .any)["v2t.debugLog"].waitForExistence(timeout: 5), "no debug log dot in the bar")
    for ch in "teh" { key("letters-\(ch)").tap() }
    key("space").tap()
    waitForText("The ")
    key("delete").tap()
    let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'v2t.suggestion.' AND label == '“Teh”'")).firstMatch
    XCTAssertTrue(original.waitForExistence(timeout: 3))
    original.tap()
    waitForText("Teh ")
    for ch in "keyb" { key("letters-\(ch)").tap() }
    let keyboard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'v2t.suggestion.' AND label == 'keyboard'")).firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
    keyboard.tap()
    waitForText("Teh keyboard ")
    let start = key("letters-t").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = key("letters-o").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.05)
    let swiped = Date().addingTimeInterval(3)
    while text == "Teh keyboard ", Date() < swiped { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertNotEqual(text, "Teh keyboard ", "the swipe typed nothing")
    shot("21-debug-log-dot-in-bar")
    app.buttons["v2t.dismiss"].tap()  // the keyboard closes and writes what it holds
    sleep(2)

    // the app now has a log to export; then the switch goes off again for the other tests
    openKeyboardSettings()
    XCTAssertFalse(app.staticTexts["Empty"].exists, "nothing was recorded")
    XCTAssertTrue(app.buttons["settings.debugLogExport"].isEnabled)
    shot("22-debug-log-recorded")
    flip(logSwitch)
    XCTAssertEqual(logSwitch.value as? String, "0")
  }
}
