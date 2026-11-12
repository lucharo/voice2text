import StoreKit

/// Whether the home page shows its Debugging section (the keyboard debug log, the typing exercise): in TestFlight
/// builds, debug builds and the Simulator, never in a build from the App Store.
enum DebuggingVisibility {
  /// The rule. `environment` is the App Store server environment that signed this install, nil when it could not
  /// be read; Debugging is then hidden, as in an App Store build.
  ///
  /// TestFlight is told from the App Store by that environment. Apple: "Apps in the development and beta-testing
  /// stages of your product cycle use the sandbox environment for Apple In-App Purchases. These apps include: …
  /// Apps you download from TestFlight"
  /// (https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox), and
  /// `AppTransaction.environment` is "The server environment that signs the app transaction."
  /// (https://developer.apple.com/documentation/storekit/apptransaction/environment). So `.production` is the App
  /// Store; `.sandbox` (TestFlight, a development-signed build) and `.xcode` (StoreKit Testing) show it.
  static func shows(environment: AppStore.Environment?, debugBuild: Bool, simulator: Bool) -> Bool {
    if debugBuild || simulator { return true }
    guard let environment else { return false }
    return environment != .production
  }

  /// A hidden section turns the debug log off: a log left on by a TestFlight build would otherwise record for the
  /// rest of its 24 hours in a build with no switch to stop it or Export to read it.
  static func apply(shows: Bool, to settings: Settings) {
    if !shows { settings.keyboardDebugLogUntil = nil }
  }

  /// Known without asking StoreKit: a debug build or the Simulator always shows the section.
  static var shownByBuild: Bool { debugBuild || simulator }

  /// This install's answer. Asks StoreKit only in a release build on a device; an unverified app transaction still
  /// names its environment, which is enough to decide whether to show a debugging section.
  static func current() async -> Bool {
    if shownByBuild { return true }
    var environment: AppStore.Environment?
    if let result = try? await AppTransaction.shared {
      switch result {
      case .verified(let t), .unverified(let t, _): environment = t.environment
      }
    }
    return shows(environment: environment, debugBuild: false, simulator: false)
  }

  private static var debugBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }

  private static var simulator: Bool {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
  }
}
