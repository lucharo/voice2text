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

  /// typeText drives Apple's keyboard, so hand over from v2t's when v2t's is up.
  @MainActor func typeWithAppleKeyboard(_ text: String, into field: XCUIElement, app: XCUIApplication) {
    field.tap()
    if app.descendants(matching: .any)["key.space"].waitForExistence(timeout: 2) { leaveV2TKeyboard(app) }
    field.typeText(text)
  }

  /// Hands over from v2t's keyboard to the next one: with v2t's own globe key where it has one (iPads, Touch
  /// ID iPhones), else with the globe iOS draws below the keyboard (Face ID iPhones, where v2t's slot holds
  /// its emoji key).
  @MainActor func leaveV2TKeyboard(_ app: XCUIApplication) {
    let v2tGlobe = app.descendants(matching: .any)["key.globe"]
    if v2tGlobe.exists { v2tGlobe.tap(); return }
    app.buttons["Next keyboard"].firstMatch.tap()
  }

  /// Swipes `app`'s main list down until `element` sits below the navigation bar, where a tap reaches it: a row
  /// under the bar still reads as hittable, but the tap lands on the bar.
  @MainActor func revealAbove(_ element: XCUIElement, in app: XCUIApplication) {
    let bar = app.navigationBars.firstMatch
    for _ in 0..<10 where !(element.exists && element.isHittable && element.frame.minY >= bar.frame.maxY) {
      app.swipeDown(velocity: .slow)
    }
  }

  /// Swipes `app`'s main list up until `element` can be tapped (at most six swipes).
  @MainActor func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
  }
}
