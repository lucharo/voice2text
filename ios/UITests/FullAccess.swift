import XCTest

extension XCTestCase {
  /// The app's "Allow Full Access" setup row opens Settings, then Keyboards › v2t › Allow Full Access, as a
  /// user would. On the iOS 27.1 Simulator the link opens Settings' top level rather than v2t's own page, so
  /// both routes are handled.
  @MainActor func allowFullAccess() {
    let app = XCUIApplication()
    app.launch()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow Full Access'")).firstMatch.tap()
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30))  // Settings opens slowly on a busy Mac
    let route = settings.staticTexts["Keyboards"].firstMatch.waitForExistence(timeout: 10) ? ["Keyboards"] : ["General", "Keyboard", "Keyboards", "v2t"]
    for label in route {
      let row = settings.staticTexts[label].firstMatch
      for _ in 0..<6 where !row.waitForExistence(timeout: 1) { settings.swipeUp(velocity: .slow) }  // rows load as they scroll in
      XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(label) in Settings")
      let cell = settings.cells.containing(.staticText, identifier: label).firstMatch
      (cell.exists ? cell : row).tap()
      sleep(1)
    }
    let added = settings.switches["v2t"].firstMatch
    if added.waitForExistence(timeout: 5), (added.value as? String) != "1" { added.switches.firstMatch.exists ? added.switches.firstMatch.tap() : added.tap() }
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
}
