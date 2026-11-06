import XCTest

/// The emoji key and v2t's emoji panel in the Simulator: the key's slot, typing an emoji, the categories, a
/// skin tone by long press, the recents, delete and ABC.
@MainActor final class EmojiUITests: XCTestCase {
  let app = XCUIApplication()

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }
  func emoji(_ e: String) -> XCUIElement { app.descendants(matching: .any)["emoji.\(e)"].firstMatch }
  var field: XCUIElement { app.textFields["v2t.try"] }
  var text: String { field.value as? String ?? "" }

  func launch(globe: String? = nil) {
    continueAfterFailure = false
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    if let globe { app.launchEnvironment["V2T_PREVIEW_GLOBE"] = globe }
    app.launch()
    _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch.waitForExistence(timeout: 120)
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    // a keyboard extension's first start after an install can take several seconds
    for _ in 0..<8 where !key("letters-q").waitForExistence(timeout: 8) {
      // a fresh Simulator's Apple keyboard first shows a one-time introduction with a Continue button
      let intro = app.buttons["Continue"]
      if intro.exists { intro.tap(); continue }
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() } else { field.tap() }  // no keyboard came up at all (seen after a reinstall)
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
  }

  func waitForText(_ want: String, file: StaticString = #filePath, line: UInt = #line) {
    let settled = Date().addingTimeInterval(3)
    while text != want, Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(text, want, file: file, line: line)
  }

  /// The emoji key sits after 123, in the globe's slot, when iOS draws its own globe below the keyboard; with
  /// no such globe, v2t's globe comes first.
  func testEmojiKeyTakesTheGlobesSlotWhenIOSDrawsAGlobe() {
    launch()
    shot("50-keyboard-emoji-key")
    XCTAssertTrue(key("emoji").exists)
    XCTAssertEqual(key("emoji").frame.midY, key("space").frame.midY, accuracy: 1)
    XCTAssertLessThan(key("emoji").frame.maxX, key("space").frame.minX)
    if key("globe").exists {
      XCTAssertLessThan(key("globe").frame.maxX, key("emoji").frame.minX)
    } else {
      XCTAssertLessThan(key("page").frame.maxX, key("emoji").frame.minX)
      XCTAssertTrue(app.buttons["Next keyboard"].exists, "no globe from v2t and none from iOS: no way to switch keyboards")
    }
  }

  /// Where iOS draws no globe (Touch ID iPhones, iPads), v2t's globe stays, before the emoji key, and still
  /// hands over to the next keyboard. Forced on here, since the Simulator is a Face ID iPhone.
  func testTheGlobeStaysBeforeTheEmojiKeyWhenIOSDrawsNone() {
    launch(globe: "1")
    XCTAssertTrue(key("globe").waitForExistence(timeout: 5))
    if UIDevice.current.userInterfaceIdiom == .phone {  // the iPad's row starts with the globe, before its page key
      XCTAssertLessThan(key("page").frame.maxX, key("globe").frame.minX)
    }
    XCTAssertLessThan(key("globe").frame.maxX, key("emoji").frame.minX)
    XCTAssertLessThan(key("emoji").frame.maxX, key("space").frame.minX)
    shot("54-keyboard-globe-and-emoji")
    key("emoji").tap()  // the panel covers the keys' globe, so it has its own
    XCTAssertTrue(app.buttons["emoji.globe"].waitForExistence(timeout: 3))
    app.buttons["emoji.abc"].tap()
    key("globe").tap()
    XCTAssertTrue(key("letters-q").waitForNonExistence(timeout: 5), "the globe did not hand over to the next keyboard")
  }

  func testEmojiPanelTypesAnEmojiAndGoesBackToLetters() {
    launch(globe: "0")
    shot("55-keyboard-emoji-only")  // the bottom row with iOS's own globe below the keyboard, as on a Face ID iPhone
    key("letters-h").tap()
    key("letters-i").tap()
    key("emoji").tap()
    XCTAssertTrue(app.descendants(matching: .any)["v2t.emoji"].waitForExistence(timeout: 3))
    app.buttons["emoji.category.smileys"].tap()  // past any recents a previous run left
    XCTAssertTrue(emoji("😀").waitForExistence(timeout: 3))
    shot("51-emoji-panel")
    emoji("😀").tap()
    waitForText("Hi😀")

    app.buttons["emoji.category.flags"].tap()
    XCTAssertEqual(app.staticTexts["emoji.header"].label, "FLAGS")
    XCTAssertTrue(emoji("🏁").waitForExistence(timeout: 3))  // the first flag
    shot("52-emoji-flags")

    XCTAssertFalse(app.buttons["emoji.globe"].exists, "iOS draws the globe below the keyboard here")
    app.buttons["emoji.delete"].tap()
    waitForText("Hi")
    app.buttons["emoji.abc"].tap()
    XCTAssertTrue(key("letters-q").isHittable)
    key("space").tap()
    waitForText("Hi ")
  }

  /// A long press on 👋 offers its skin tones; sliding to the fourth (medium) types 👋🏽, which then leads the
  /// recents and stands in for 👋 in its category.
  func testLongPressPicksASkinToneThatIsRemembered() {
    launch(globe: "0")
    key("emoji").tap()
    app.buttons["emoji.category.smileys"].tap()
    let width = app.windows.firstMatch.frame.width, y = app.buttons["emoji.abc"].frame.minY - 80
    // 👋 in any skin tone (an earlier run may have picked one), near the middle, where the whole picker fits
    func wave() -> XCUIElement? {
      let ids = ["👋", "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"].map { "emoji.\($0)" }
      let all = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ids))
      return (0..<all.count).map { all.element(boundBy: $0) }.first { $0.frame.midX > 100 && $0.frame.midX < width - 150 }
    }
    let origin = app.coordinate(withNormalizedOffset: .zero)
    for _ in 0..<40 where wave() == nil {
      // drag the grid 150 pt at a time and hold, so it does not fling past
      origin.withOffset(CGVector(dx: width - 40, dy: y))
        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: width - 190, dy: y)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    let found = wave()
    XCTAssertNotNil(found, "👋 never scrolled into view; the header reads \(app.staticTexts["emoji.header"].label)")
    guard let found else { return }
    // the picker is centred on the emoji, one cell per option: the fourth option is half a cell to its right
    let start = found.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let medium = found.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
    start.press(forDuration: 0.8, thenDragTo: medium, withVelocity: 100, thenHoldForDuration: 0.3)
    waitForText("👋🏽")
    XCTAssertTrue(emoji("👋🏽").exists, "the category still shows the yellow 👋")
    app.buttons["emoji.abc"].tap()
    key("emoji").tap()
    XCTAssertTrue(app.buttons["emoji.category.recents"].isSelected)
    XCTAssertEqual(app.staticTexts["emoji.header"].label, "FREQUENTLY USED")
    XCTAssertTrue(emoji("👋🏽").isHittable)
    shot("53-emoji-recents")
  }

  /// Search: the keys come back and type into the field; a result goes into the document; back returns to
  /// the panel.
  func testSearchTypesIntoTheFieldAndInsertsAResult() {
    launch(globe: "0")
    key("emoji").tap()
    XCTAssertEqual(app.buttons["emoji.search.open"].label, "Search Emoji")  // titled from the start
    app.buttons["emoji.search.open"].tap()
    XCTAssertTrue(key("letters-p").waitForExistence(timeout: 3))
    for ch in "pizz" { key("letters-\(ch)").tap() }
    XCTAssertEqual(app.descendants(matching: .any)["emoji.search.field"].value as? String, "pizz")
    XCTAssertFalse(text.contains("piz"), "search typed into the document: \(text)")  // an empty field reads as its placeholder
    let pizza = app.buttons["emoji.result.🍕"]
    XCTAssertTrue(pizza.waitForExistence(timeout: 3))
    shot("56-emoji-search")
    pizza.tap()
    waitForText("🍕")
    key("delete").tap()  // deletes in the field, not the document
    XCTAssertEqual(app.descendants(matching: .any)["emoji.search.field"].value as? String, "piz")
    XCTAssertEqual(text, "🍕")
    key("shift").tap()  // search's own shift: a capital in the field, matched case-insensitively
    key("letters-z").tap()
    XCTAssertEqual(app.descendants(matching: .any)["emoji.search.field"].value as? String, "pizZ")
    XCTAssertTrue(app.buttons["emoji.result.🍕"].waitForExistence(timeout: 3))
    app.buttons["emoji.search.back"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["v2t.emoji"].waitForExistence(timeout: 3))
    app.buttons["emoji.abc"].tap()
    key("letters-a").tap()
    waitForText("🍕a")  // lowercase: the shift tapped in search did not reach the document's shift
  }

  /// The bar offers 🍕 after "pizza" in its last slot; tapping it replaces the word.
  func testTheBarOffersTheWordsEmoji() {
    launch(globe: "0")
    for ch in "pizza" { key("letters-\(ch)").tap() }
    let slot = app.buttons["v2t.suggestion.2"]
    let deadline = Date().addingTimeInterval(3)
    while slot.label != "🍕", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    XCTAssertEqual(slot.label, "🍕")
    shot("57-bar-emoji")
    slot.tap()
    waitForText("🍕 ")
  }
}
