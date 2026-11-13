import XCTest

/// The keyboard-to-app dictation loop in the Simulator with a synthetic clip (V2T_FIXTURE_AUDIO) standing in for
/// the microphone: Full Access on, the mic session warm, then the keyboard's mic key starts and stops a
/// dictation that the app transcribes on the device and the keyboard types.
@MainActor final class DictationUITests: XCTestCase {
  static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../build/fixtures/dictation-en.wav").standardized.path()

  func testKeyboardMicDictatesThroughTheApp() throws {
    continueAfterFailure = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixture), "run ios/setup.sh to make \(Self.fixture)")
    allowFullAccess()

    let app = XCUIApplication.v2t()
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    app.launchEnvironment["V2T_FIXTURE_AUDIO"] = Self.fixture
    app.launch()
    downloadModelIfNeeded(app)
    let ready = modelReady(app)
    shot("11-model-ready")

    // a replacement the dictation must pass through: "simulator" is in the fixture clip
    let dictionary = app.buttons["Dictionary"]
    reveal(dictionary, in: app)
    dictionary.tap()
    if !app.staticTexts["iPhone Simulator"].waitForExistence(timeout: 2) {
      typeWithAppleKeyboard("simulator", into: app.textFields["v2t.dict.heard"], app: app)
      app.textFields["v2t.dict.written"].tap()
      app.textFields["v2t.dict.written"].typeText("iPhone Simulator")
      app.buttons["v2t.dict.addReplacement"].tap()
    }
    XCTAssertTrue(app.staticTexts["iPhone Simulator"].waitForExistence(timeout: 5))
    app.terminate()
    app.launch()
    XCTAssertTrue(ready.waitForExistence(timeout: 120))

    let warm = app.switches["v2t.warm"].firstMatch
    reveal(warm, in: app)
    XCTAssertTrue(warm.waitForExistence(timeout: 5))
    // a tap on a row that is still settling can miss: tap until the switch reads on, then let the stop row appear
    func isOn() -> Bool { "\(warm.value ?? "")" == "1" }
    for _ in 0..<3 where !isOn() {
      warm.switches.firstMatch.exists ? warm.switches.firstMatch.tap() : warm.tap()
      let until = Date().addingTimeInterval(3)
      while !isOn(), Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    }
    XCTAssertTrue(isOn(), "mic-ready switch never turned on")
    sleep(1)  // the stop row is added once the session state publishes; revealing before that scrolls past it
    let stopMic = app.buttons["v2t.stopMic"]
    reveal(stopMic, in: app)
    XCTAssertTrue(stopMic.waitForExistence(timeout: 5), app.debugDescription)
    shot("12-mic-session-on")

    let field = app.textFields["v2t.try"]
    revealAbove(field, in: app)  // revealing the stop row scrolled it away, maybe to under the navigation bar
    sleep(1)  // let the list settle, or the tap lands on whatever scrolled under it
    let key = { (id: String) in app.descendants(matching: .any)["key.\(id)"] }
    // an earlier test may have left Apple's keyboard up: step through the keyboards to v2t's, as a user would.
    // On a full-suite run the first focus sometimes raises no keyboard at all, so focus again once.
    for _ in 0..<2 where !key("letters-q").exists {
      field.tap()
      for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
        // a fresh Simulator's Apple keyboard first shows a one-time introduction with a Continue button, as in EmojiUITests
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); continue }
        if app.buttons["Next keyboard"].exists { app.buttons["Next keyboard"].tap() }
      }
    }
    XCTAssertTrue(key("mic").waitForExistence(timeout: 10), app.debugDescription)
    shot("12b-keyboard-v2t-mic")
    key("mic").tap()
    // recording covers the keys with the waveform panel; Done stops it and types the text
    let done = app.buttons["v2t.recording.done"]
    XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
    sleep(1)
    shot("13-listening")
    done.tap()
    let deadline = Date().addingTimeInterval(120)
    while ((field.value as? String) ?? "").lowercased().contains("keyboard") == false, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    // for a moment the bar says how long the wait after Done took. The app sends the text before it reports
    // idle, so the notice comes once the panel closes, just after the text (it clears after 2 s: look now)
    let notice = app.staticTexts["v2t.notice"]
    let sawNotice = notice.waitForExistence(timeout: 1.5) && notice.label.hasPrefix("Done in ")
    shot("14-dictated-text")
    XCTAssertTrue(((field.value as? String) ?? "").lowercased().contains("keyboard"), "field: \(field.value ?? "nil")")
    XCTAssertTrue(sawNotice, "no 'Done in' notice once the text was typed")
    XCTAssertTrue(((field.value as? String) ?? "").contains("iPhone Simulator"), "replacement not applied: \(field.value ?? "nil")")

    // the keyboard has now opened with Full Access, so both setup steps read done after a relaunch
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Done: the v2t keyboard is on."].waitForExistence(timeout: 10))
    shot("15-setup-done")

    // History keeps what was heard beside the text the dictionary changed
    let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'History'")).firstMatch
    reveal(history, in: app)
    history.tap()
    let heard = app.buttons["v2t.history.heard"].firstMatch  // closed by default: open the newest card's
    XCTAssertTrue(heard.waitForExistence(timeout: 5), app.debugDescription)
    heard.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Heard: '")).firstMatch.waitForExistence(timeout: 5))
    shot("16-history-heard")
  }
}
