import XCTest

extension XCTestCase {
  /// A full-resolution screenshot kept in the test report, and also written as `<name>.png` to the folder in
  /// V2T_SHOTS when set (pass TEST_RUNNER_V2T_SHOTS=<dir> to xcodebuild), for visual review.
  @MainActor func shot(_ name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let a = XCTAttachment(screenshot: screenshot)
    a.name = name
    a.lifetime = .keepAlways
    add(a)
    if let dir = ProcessInfo.processInfo.environment["V2T_SHOTS"] {
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }
  }

  /// typeText drives Apple's keyboard, so hand over from v2t's with its globe key when v2t's is up.
  @MainActor func typeWithAppleKeyboard(_ text: String, into field: XCUIElement, app: XCUIApplication) {
    field.tap()
    let v2tGlobe = app.descendants(matching: .any)["key.emoji"]
    if v2tGlobe.waitForExistence(timeout: 2) { v2tGlobe.tap() }
    field.typeText(text)
  }

  /// Swipes `app`'s main list up until `element` can be tapped (at most six swipes).
  @MainActor func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
  }
}
