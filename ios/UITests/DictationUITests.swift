import XCTest

/// The keyboard-to-app dictation loop in the Simulator with a synthetic clip (V2T_FIXTURE_AUDIO) standing in for
/// the microphone: Full Access on, the mic session warm, then the keyboard's mic key starts and stops a
/// dictation that the app transcribes on the device and the keyboard types.
@MainActor final class DictationUITests: XCTestCase {
  static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../build/fixtures/dictation-en.wav").standardized.path()

  func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  /// Settings › General › Keyboard › Keyboards › v2t › Allow Full Access, as a user would.
  func allowFullAccess() {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    for label in ["General", "Keyboard", "Keyboards", "v2t"] {
      let row = settings.staticTexts[label].firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(label) in Settings")
      row.tap()
    }
    let toggle = settings.switches["Allow Full Access"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    if (toggle.value as? String) != "1" {
      toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
      let allow = settings.alerts.buttons["Allow"].firstMatch
      if allow.waitForExistence(timeout: 5) { allow.tap() }
    }
    shot("10-full-access")
    settings.terminate()
  }

  func testKeyboardMicDictatesThroughTheApp() throws {
    continueAfterFailure = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixture), "run ios/setup.sh to make \(Self.fixture)")
    allowFullAccess()

    let app = XCUIApplication()
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    app.launchEnvironment["V2T_FIXTURE_AUDIO"] = Self.fixture
    app.launch()
    // the speech model downloads once (627 MB) and loads; allow for a slow network
    let ready = app.staticTexts["Ready. Transcription runs on this iPhone, offline."]
    XCTAssertTrue(ready.waitForExistence(timeout: 1200), "model never became ready")
    shot("11-model-ready")

    let warm = app.switches["v2t.warm"].firstMatch
    XCTAssertTrue(warm.waitForExistence(timeout: 5))
    if (warm.value as? String) != "1" { warm.switches.firstMatch.exists ? warm.switches.firstMatch.tap() : warm.tap() }
    XCTAssertTrue(app.buttons["v2t.stopMic"].waitForExistence(timeout: 5))
    shot("12-mic-session-on")

    let field = app.textFields["v2t.try"]
    field.tap()
    let key = { (id: String) in app.descendants(matching: .any)["key.\(id)"] }
    for _ in 0..<3 where !key("letters-q").waitForExistence(timeout: 3) {
      if app.buttons["Next keyboard"].exists { app.buttons["Next keyboard"].tap() }
    }
    XCTAssertTrue(key("mic").waitForExistence(timeout: 10))
    key("mic").tap()
    sleep(1)
    shot("13-listening")
    key("mic").tap()
    let deadline = Date().addingTimeInterval(120)
    while ((field.value as? String) ?? "").lowercased().contains("keyboard") == false, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    shot("14-dictated-text")
    XCTAssertTrue(((field.value as? String) ?? "").lowercased().contains("keyboard"), "field: \(field.value ?? "nil")")
  }
}
