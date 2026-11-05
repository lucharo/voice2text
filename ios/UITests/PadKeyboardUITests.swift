import XCTest

/// The iPad keyboard in an iPad Simulator: its own rows (delete and return on the right, a shift at each
/// end, hide keyboard), typing through them, landscape, Spanish, and the hide key. Skipped on an iPhone.
@MainActor final class PadKeyboardUITests: XCTestCase {
  let app = XCUIApplication()

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }
  var field: XCUIElement { app.textFields["v2t.try"] }
  var text: String { field.value as? String ?? "" }

  override func setUp() async throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDown() async throws {
    XCUIDevice.shared.orientation = .portrait
  }

  func launch(layout: String = "en") {
    app.launchEnvironment["V2T_LAYOUT"] = layout
    app.launch()
    _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch.waitForExistence(timeout: 120)
  }

  func showKeyboard() {
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
  }

  func type(_ s: String) {
    for ch in s { ch == " " ? key("space").tap() : key("letters-\(String(ch).lowercased())").tap() }
  }

  func testTheIPadRowsTypeAndHide() {
    launch()
    showKeyboard()
    for id in ["delete", "return", "shift", "shift-right", "letters-,", "letters-.", "page-right", "dismiss", "mic", "globe", "emoji"] {
      XCTAssertTrue(key(id).exists, "no key.\(id)")
    }
    // delete ends the top row (letters on most iPads, numbers on a 13-inch), return the home row
    let top = key("letters-0").exists ? key("letters-0") : key("letters-p")
    XCTAssertEqual(key("delete").frame.midY, top.frame.midY, accuracy: 1)
    XCTAssertGreaterThan(key("delete").frame.minX, top.frame.maxX)
    XCTAssertEqual(key("return").frame.midY, key("letters-l").frame.midY, accuracy: 1)
    shot("40-ipad-keyboard-portrait")

    type("hello there")
    key("letters-.").tap()
    let settled = Date().addingTimeInterval(3)
    while text != "Hello there.", Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(text, "Hello there.")
    shot("41-ipad-typed")

    key("dismiss").tap()
    XCTAssertTrue(key("letters-q").waitForNonExistence(timeout: 5), "hide keyboard left the keyboard up")
  }

  /// On a 13-inch iPad: the full keyboard, with shift typing a number key's second mark and tab a tab.
  func testThirteenInchFullKeyboard() throws {
    let screen = XCUIScreen.main.screenshot().image.size
    try XCTSkipUnless(min(screen.width, screen.height) >= 1000, "13-inch iPad only")
    launch()
    showKeyboard()
    for id in ["letters-1", "letters-`", "tab", "capslock", "letters-;", "letters-/"] { XCTAssertTrue(key(id).exists, "no key.\(id)") }
    key("letters-h").tap(); key("letters-i").tap()
    key("shift").tap(); key("letters-1").tap()
    let settled = Date().addingTimeInterval(3)
    while text != "Hi!", Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(text, "Hi!")
    shot("48-ipad-13in-full-typed")
  }

  func testLandscapeKeysAreTaller() {
    launch()
    showKeyboard()
    let portrait = key("letters-q").frame
    XCUIDevice.shared.orientation = .landscapeLeft
    let deadline = Date().addingTimeInterval(5)
    while key("letters-q").frame.width <= portrait.width + 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    let landscape = key("letters-q").frame
    XCTAssertGreaterThan(landscape.width, portrait.width)
    XCTAssertGreaterThan(landscape.height, portrait.height)
    shot("42-ipad-keyboard-landscape")
  }

  func testSpanishIPadRowEndsWithEnyeAndIntro() {
    launch(layout: "es")
    showKeyboard()
    XCTAssertTrue(key("letters-ñ").exists)
    XCTAssertEqual(key("return").frame.midY, key("letters-ñ").frame.midY, accuracy: 1)
    XCTAssertGreaterThan(key("return").frame.minX, key("letters-ñ").frame.maxX)
    type("manana")
    let settled = Date().addingTimeInterval(3)
    while !text.hasPrefix("Mañana"), Date() < settled { key("space").tap(); RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    XCTAssertTrue(text.hasPrefix("Mañana"), text)
    shot("43-ipad-spanish")
  }

  func testAppleIPadKeyboardBaseline() {
    launch()
    showKeyboard()
    key("globe").tap()  // hands over to Apple's keyboard, for a side-by-side comparison
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "space").firstMatch.waitForExistence(timeout: 5))
    shot("44-apple-ipad-keyboard-portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    sleep(2)
    shot("45-apple-ipad-keyboard-landscape")
    XCUIDevice.shared.orientation = .portrait
    sleep(1)
    app.buttons["Next keyboard"].firstMatch.tap()  // back to v2t for the next run
  }

  func testCompanionAppOnIPad() {
    launch()
    shot("46-ipad-app-portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    sleep(2)
    shot("47-ipad-app-landscape")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this iPad'")).firstMatch.exists)
  }
}
