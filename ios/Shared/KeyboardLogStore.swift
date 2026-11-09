import Foundation

/// Where the keyboard debug log lives (#162), for the keyboard that writes it and the app that exports and
/// clears it. The writing itself is `KeyboardDebugLog` in V2TKeyboardCore.
enum KeyboardLogStore {
  /// The log switches itself off this long after it was turned on.
  static let lifetime: TimeInterval = 24 * 3600

  /// In the App Group, where the app can read it and `ios/tools/fetch_kb_log.sh` can copy it off the phone. The
  /// keyboard reaches it only with Full Access.
  static var groupDirectory: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Settings.group)?.appending(path: "KeyboardLog")
  }

  /// The keyboard's own container: used when it cannot write to the App Group. The app cannot export from it.
  static var localDirectory: URL { URL.cachesDirectory.appending(path: "KeyboardLog") }
}
