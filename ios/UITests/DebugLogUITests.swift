import XCTest

/// The keyboard debug log (#162) end to end: the app's switch turns it on, the keyboard shows its red dot and
/// records typing, a swipe, a correction and its revert and a suggestion tap, and the app then shows a log to
/// export. The log it leaves in the Simulator's App Group is what `ios/tools/kb_log_report.py` was tried on.
@MainActor final class DebugLogUITests: XCTestCase {
  let app = XCUIApplication.v2t()

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

  /// Scrolls the list until `element` sits clear of the bottom edge: `reveal` stops at a row that is only just
  /// on screen, where a tap lands on the home indicator.
  func scrollIntoView(_ element: XCUIElement) {
    let bottom = app.windows.firstMatch.frame.maxY - 120
    for _ in 0..<8 where !(element.exists && element.isHittable && element.frame.maxY < bottom) { app.swipeUp(velocity: .slow) }
  }

  /// The home page's Debugging section, scrolled into view: its rows are on the first page, with no screen to open.
  func scrollToDebugging() {
    scrollIntoView(logSwitch)
    XCTAssertTrue(logSwitch.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.navigationBars["v2t"].exists, "Debugging is not on the first page")
  }

  /// The Log row's text ("Log", then "Empty" or a size), however SwiftUI exposes the LabeledContent.
  var logSize: String {
    let row = app.descendants(matching: .any)["settings.debugLogSize"].firstMatch
    guard row.waitForExistence(timeout: 5) else { return "" }
    return "\(row.label) \(row.value as? String ?? "") " + row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
  }

  func flip(_ s: XCUIElement) { s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap() }

  func waitForText(_ want: String) {
    let settled = Date().addingTimeInterval(3)
    while text != want, Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(text, want)
  }

  func testSwitchDotAndRecording() {
    launch()
    // whatever happens, the log is off again for the tests after this one
    addTeardownBlock { @MainActor in
      let app = XCUIApplication.v2t()
      app.terminate()
      app.launchEnvironment["V2T_KEYBOARD_LOG_OFF"] = "1"  // off, its file kept for kb_log_report.py
      app.launch()
      app.terminate()
    }
    scrollToDebugging()
    XCTAssertEqual(logSwitch.value as? String, "0", "off by default")
    XCTAssertTrue(logSize.contains("Empty"), "log row: \(logSize)")
    flip(logSwitch)
    XCTAssertEqual(logSwitch.value as? String, "1")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On until'")).firstMatch.exists)
    shot("20-debug-log-switch-on")

    // the keyboard: its dot shows, and what is typed is recorded
    revealAbove(field, in: app)  // back up the long first page, from Debugging at its foot
    // a tap while the list still glides after the swipe can miss the field: tap until a keyboard shows
    for _ in 0..<3 where !(key("letters-q").exists || app.keyboards.firstMatch.exists) {
      field.tap()
      _ = key("letters-q").waitForExistence(timeout: 2) || app.keyboards.firstMatch.waitForExistence(timeout: 1)
    }
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      // a fresh Simulator shows Apple's keyboard tips first; each has a Continue button over the globe
      let tip = app.buttons["Continue"].firstMatch
      if tip.exists { tip.tap(); continue }
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
    // the keyboard writes what it holds within a second; closing the app then takes the keyboard down. Not the
    // bar's hide button: in the Simulator that turns on iOS's keyboard minimisation, which parks the keyboard
    // below the screen for every test after this one
    sleep(2)
    app.terminate()
    app.launchEnvironment["V2T_RESET_KEYBOARD_LOG"] = nil  // keep the log just made
    app.launch()

    // the app now has a log to export; then the switch goes off again for the other tests
    scrollToDebugging()
    XCTAssertFalse(logSize.contains("Empty"), "nothing was recorded; log row: \(logSize)")
    XCTAssertTrue(app.buttons["settings.debugLogExport"].isEnabled)
    shot("22-debug-log-recorded")
    flip(logSwitch)
    XCTAssertEqual(logSwitch.value as? String, "0")
  }
}
