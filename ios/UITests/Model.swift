import XCTest

extension XCTestCase {
  /// The speech model's ready line in the app's setup list.
  @MainActor func modelReady(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch
  }

  /// Taps Download when the model is not on the Simulator yet (the app never downloads it by itself, #124), then
  /// waits for it to be ready: 627 MB once, so allow for a slow network.
  @MainActor func downloadModelIfNeeded(_ app: XCUIApplication) {
    let download = app.buttons["v2t.model.download"]
    if !modelReady(app).waitForExistence(timeout: 5), download.waitForExistence(timeout: 30) { download.tap() }
    XCTAssertTrue(modelReady(app).waitForExistence(timeout: 1200), "model never became ready")
  }
}
