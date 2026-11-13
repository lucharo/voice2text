import StoreKit

/// The app's half of `DebuggingVisibility`: which build this is, from StoreKit, and recording the answer for the
/// keyboard.
extension DebuggingVisibility {
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

  /// Records the decision for the keyboard. Shown: `install` may log. Hidden: the debug log goes off and no install
  /// may log, so a log left on by a TestFlight build does not record on in a build with no switch to stop it.
  static func apply(shows: Bool, install: String?, to settings: Settings) {
    if shows {
      settings.debuggingInstall = install
    } else {
      settings.keyboardDebugLogUntil = nil
      settings.debuggingInstall = nil
    }
  }

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
}
