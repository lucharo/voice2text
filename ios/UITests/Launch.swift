import XCTest

extension XCUIApplication {
  /// The v2t app with About v2t already seen, so a test starts on the setup list even on a fresh Simulator, where
  /// the first launch would open About v2t over it. AboutUITests sets V2T_FIRST_LAUNCH itself.
  static func v2t() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["V2T_FIRST_LAUNCH"] = "0"
    return app
  }
}
