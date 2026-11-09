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
    // a fresh Simulator clone has not added the keyboard yet: add it once, as KeyboardUITests does
    if !app.staticTexts["Done: the v2t keyboard is on."].waitForExistence(timeout: 5) {
      app.terminate()
      allowFullAccess()
      app.launch()
    }
    let field = app.textFields["v2t.try"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    sleep(2)  // the setup list settles before the field is tapped
    field.tap()
    // while the recording view is up the keys are hidden from accessibility, so look for the panel instead
    let v2t = preview == nil || preview == "done" ? key("letters-q") : app.staticTexts["v2t.recording.status"]
    for _ in 0..<5 where !v2t.waitForExistence(timeout: 3) {
      // a fresh Simulator's Apple keyboard first shows a one-time introduction with a Continue button
      if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); continue }
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(v2t.waitForExistence(timeout: 10), app.debugDescription)
    if preview != nil, preview != "done" { XCTAssertFalse(key("letters-q").exists, "keys under the recording view are still in the accessibility tree") }
    sleep(2)  // let the preview waveform fill
  }

  func testRecordingView() {
    showKeyboard(preview: "listening")
    XCTAssertTrue(app.buttons["v2t.recording.done"].isHittable && app.buttons["v2t.recording.cancel"].isHittable)
    shot("rec-listening")
    app.terminate()
    showKeyboard(preview: "transcribing")
    XCTAssertFalse(app.buttons["v2t.recording.done"].isHittable)
    // the wait after Done counts up in tenths of a second: the stage is the label, the time its value
    let status = app.staticTexts["v2t.recording.status"]
    XCTAssertEqual(status.label, "Transcribing…")
    let first = "\(status.value ?? "")"
    sleep(1)
    let later = "\(status.value ?? "")"
    XCTAssertTrue(first.hasSuffix(" s") && later.hasSuffix(" s") && first != later, "timer not ticking: \(first) then \(later)")
    shot("rec-transcribing")
    app.terminate()
    showKeyboard(preview: "cleaningUp")
    XCTAssertEqual(app.staticTexts["v2t.recording.status"].label, "Cleaning up…")
    shot("rec-cleaning-up")
    app.terminate()
  }

  /// Once the text is in, the keys are back and the bar says how long it took, for a moment.
  func testTheBarSaysHowQuickItWas() {
    showKeyboard(preview: "done")
    let notice = app.staticTexts["v2t.notice"]
    XCTAssertTrue(notice.waitForExistence(timeout: 5))
    XCTAssertEqual(notice.label, "Done in 1.4 s")
    shot("rec-done-in")
    key("letters-a").tap()  // typing again brings the suggestions back
    let gone = Date().addingTimeInterval(3)
    while notice.exists, Date() < gone { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    XCTAssertFalse(notice.exists, "the notice stays after a key")
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
