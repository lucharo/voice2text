import XCTest

/// The keyboard's look in light and dark mode (the suggestion bar against the keys, the mic key, the space
/// bar), as full-resolution screenshots, and the hide-keyboard control.
@MainActor final class LookUITests: XCTestCase {
  let app = XCUIApplication()

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }
  var field: XCUIElement { app.textFields["v2t.try"] }

  /// The Simulator's appearance, set from outside with `xcrun simctl ui <udid> appearance dark` before the run
  /// (XCUIDevice.appearance left the keyboard light); it only names the screenshots.
  var appearance: String { ProcessInfo.processInfo.environment["V2T_APPEARANCE"] ?? "light" }

  /// Opens v2t's keyboard in the Try it field, with the mic key drawn in `micStyle` (V2T_MIC_STYLE: A, B, C or
  /// C-warm; unset draws the default).
  func showKeyboard(micStyle: String? = nil) {
    continueAfterFailure = false
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    if let micStyle { app.launchEnvironment["V2T_MIC_STYLE"] = micStyle } else { app.launchEnvironment.removeValue(forKey: "V2T_MIC_STYLE") }
    app.launch()
    // the setup list changes height as the model row goes from Preparing to Ready; tapping the field before
    // then can land on the row that moved under it
    _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch.waitForExistence(timeout: 120)
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
    onScreen(key("letters-q"))
  }

  /// Waits for `element` to be on screen: a keyboard is in the accessibility tree while it still slides in.
  func onScreen(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
    waitForExpectations(timeout: 15)
    sleep(1)  // the end of the slide-in
  }

  func testLook() {
    showKeyboard()
    shot("look-\(appearance)-empty")
    for ch in "keyb" { key("letters-\(ch)").tap() }
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'v2t.suggestion.' AND label ==[c] 'keyboard'")).firstMatch.waitForExistence(timeout: 3))
    shot("look-\(appearance)-suggestions")
  }

  /// One screenshot per mic-key style, for Luis to pick from.
  func testMicKeyStyles() {
    for style in ["A", "B", "C", "C-warm"] {
      showKeyboard(micStyle: style)
      XCTAssertEqual(key("mic").label, "dictate")
      shot("mic-\(style)-\(appearance)")
      app.terminate()
    }
  }

  /// A keyboard never sees taps outside itself, so the bar's chevron is how the user hides it.
  func testTheBarsChevronHidesTheKeyboard() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the iPad hides its keyboard with a bottom-row key instead")
    showKeyboard()
    XCTAssertEqual(key("space").label, "space")  // the "v2t" in its corner is not read out
    let chevron = app.buttons["v2t.dismiss"]
    XCTAssertTrue(chevron.waitForExistence(timeout: 3))
    XCTAssertEqual(chevron.label, "Hide keyboard")
    chevron.tap()
    expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: key("letters-q"))
    waitForExpectations(timeout: 5)
    sleep(1)
    shot("dismissed-\(appearance)")
    field.tap()  // and it comes back for the next tap in a field
    onScreen(key("letters-q"))
  }

}
