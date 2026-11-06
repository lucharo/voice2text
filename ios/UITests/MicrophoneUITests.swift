import XCTest

/// While the keyboard records, its panel names the microphone the app records from. With the synthetic clip
/// (V2T_FIXTURE_AUDIO) the app reports "Test clip", so the check does not depend on the Mac's own input.
@MainActor final class MicrophoneUITests: XCTestCase {
  func testRecordingPanelNamesTheMicrophone() throws {
    continueAfterFailure = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: DictationUITests.fixture), "run ios/setup.sh to make \(DictationUITests.fixture)")
    let app = XCUIApplication()
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    app.launchEnvironment["V2T_FIXTURE_AUDIO"] = DictationUITests.fixture
    app.launch()
    // Full Access is set once per Simulator; the setup list says so once the keyboard has opened with it
    if !app.staticTexts["Done: the v2t keyboard is on."].waitForExistence(timeout: 5) {
      app.terminate()
      allowFullAccess()
      app.launch()
    }
    let warm = app.switches["v2t.warm"].firstMatch
    reveal(warm, in: app)
    XCTAssertTrue(warm.waitForExistence(timeout: 10))
    func isOn() -> Bool { "\(warm.value ?? "")" == "1" }
    for _ in 0..<3 where !isOn() {
      warm.switches.firstMatch.exists ? warm.switches.firstMatch.tap() : warm.tap()
      let until = Date().addingTimeInterval(3)
      while !isOn(), Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    }
    XCTAssertTrue(isOn(), "mic-ready switch never turned on")
    // the app names the input beside the switch
    XCTAssertTrue(app.staticTexts["Recording from Test clip"].waitForExistence(timeout: 5), app.debugDescription)
    // the microphone choice sits under the switch, on this iPhone's microphone unless changed
    let choice = app.descendants(matching: .any)["v2t.microphoneChoice"].firstMatch
    reveal(choice, in: app)
    XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
    shot("20-app-microphone")

    let field = app.textFields["v2t.try"]
    for _ in 0..<4 where !field.isHittable { app.swipeDown(velocity: .slow) }
    sleep(1)
    let key = { (id: String) in app.descendants(matching: .any)["key.\(id)"] }
    for _ in 0..<2 where !key("letters-q").exists {
      field.tap()
      // the keyboard extension can take seconds to load on a busy Mac; switching again too soon skips past it
      for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 10) {
        if app.buttons["Next keyboard"].exists { app.buttons["Next keyboard"].tap() }
      }
    }
    XCTAssertTrue(key("mic").waitForExistence(timeout: 10), app.debugDescription)
    key("mic").tap()

    let mic = app.staticTexts["v2t.recording.mic"]
    XCTAssertTrue(mic.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertEqual(mic.label, "Microphone: Test clip")
    // V2T_HOLD_SECONDS keeps the waveform up longer, for a screen recording of it
    let hold = Double(ProcessInfo.processInfo.environment["V2T_HOLD_SECONDS"] ?? "") ?? 2
    RunLoop.current.run(until: Date().addingTimeInterval(hold))
    shot("21-keyboard-microphone")
    app.buttons["v2t.recording.cancel"].tap()
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10))
  }
}
