import XCTest

/// Drives the real v2t keyboard in the simulator through synthesized touches (XCUITest taps and drags land
/// in the keyboard's touch handlers), and keeps full-resolution screenshots as attachments.
@MainActor final class KeyboardUITests: XCTestCase {
  let app = XCUIApplication()

  func launch(layout: String = "en") {
    continueAfterFailure = false
    app.launchEnvironment["V2T_LAYOUT"] = layout
    app.launch()
  }

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }
  var field: XCUIElement { app.textFields["v2t.try"] }
  var text: String { field.value as? String ?? "" }

  func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  func showKeyboard() {
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    // the simulator may start on Apple's keyboard: switch to v2t with the globe key, as a user would
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
  }

  /// Taps keys for `s`: letters by their key, " " as space, "." from the numbers page.
  func type(_ s: String, page: String = "letters") {
    for ch in s {
      switch ch {
      case " ": key("space").tap()
      default: key("\(page)-\(String(ch).lowercased())").tap()
      }
    }
  }

  func suggestion(_ word: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'v2t.suggestion.' AND label == %@", word)).firstMatch
  }

  func testTypingCapitalisesAutocorrectsAndSuggests() {
    launch()
    showKeyboard()
    shot("01-keyboard-empty-field")
    type("teh ")
    XCTAssertEqual(text, "The ")
    type("keyb")
    XCTAssertTrue(suggestion("keyboard").waitForExistence(timeout: 3))
    shot("02-suggestions-while-typing")
    suggestion("keyboard").tap()
    XCTAssertEqual(text, "The keyboard ")
    key("page").tap()
    key("numbers-.").tap()
    XCTAssertEqual(text, "The keyboard. ")
    shot("03-after-suggestion-and-full-stop")
  }

  func testDeleteAfterAutocorrectOffersTheOriginalBack() {
    launch()
    showKeyboard()
    type("teh ")
    XCTAssertEqual(text, "The ")
    key("delete").tap()
    XCTAssertEqual(text, "The")
    XCTAssertTrue(suggestion("“Teh”").waitForExistence(timeout: 3))
    shot("04-revert-offer")
    suggestion("“Teh”").tap()
    XCTAssertEqual(text, "Teh ")
  }

  func testOneFingerSwipeTypesAWord() {
    launch()
    showKeyboard()
    // a straight drag from t to o: XCUITest can only draw straight lines, so this is "to"-shaped
    let start = key("letters-t").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = key("letters-o").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.05)
    let deadline = Date().addingTimeInterval(3)
    while text.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(text, "To")
    shot("05-after-swipe")
  }

  func testSpanishLayoutRestoresAccentsAndEnye() {
    launch(layout: "es")
    showKeyboard()
    XCTAssertTrue(key("letters-ñ").exists)
    type("manana tambien ")
    XCTAssertEqual(text, "Mañana también ")
    shot("06-spanish-layout")
  }

  func testAppleKeyboardBaseline() {
    launch()
    showKeyboard()
    key("emoji").tap()  // v2t's globe: hands over to the next keyboard, Apple's
    // Apple's keys carry bare identifiers ("space"); v2t's are prefixed ("key.space")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "space").firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    shot("07-apple-keyboard-baseline")
    app.buttons["Next keyboard"].firstMatch.tap()  // back to v2t for the next run
  }
}
