import XCTest

/// Screenshots of the keyboard's recording view, using the keyboard's preview mode (V2T_PREVIEW_RECORDING),
/// which needs no microphone session or Full Access; and of the numbers and symbols pages.
@MainActor final class RecordingViewUITests: XCTestCase {
  let app = XCUIApplication()

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }

  func showKeyboard(preview: String?) {
    continueAfterFailure = false
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    if let preview { app.launchEnvironment["V2T_PREVIEW_RECORDING"] = preview } else { app.launchEnvironment.removeValue(forKey: "V2T_PREVIEW_RECORDING") }
    app.launch()
    let field = app.textFields["v2t.try"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    sleep(2)  // the setup list settles before the field is tapped
    field.tap()
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
    sleep(2)  // let the preview waveform fill
  }

  func testRecordingView() {
    showKeyboard(preview: "listening")
    XCTAssertTrue(app.buttons["v2t.recording.done"].isHittable && app.buttons["v2t.recording.cancel"].isHittable)
    shot("rec-listening")
    app.terminate()
    showKeyboard(preview: "transcribing")
    XCTAssertFalse(app.buttons["v2t.recording.done"].isHittable)
    shot("rec-transcribing")
    app.terminate()
  }

  func testNumbersPage() {
    showKeyboard(preview: nil)
    key("page").tap()
    XCTAssertTrue(key("numbers-1").waitForExistence(timeout: 5))
    shot("numbers-page")
    key("symbols").tap()
    shot("symbols-page")
  }
}
