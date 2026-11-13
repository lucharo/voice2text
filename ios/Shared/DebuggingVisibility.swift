import Foundation

/// Whether this install may use Debugging (the keyboard debug log, the typing exercise): TestFlight builds, debug
/// builds and the Simulator, never a build from the App Store. The app decides from StoreKit and the receipt's name
/// (`DebuggingVisibility+StoreKit.swift`) and records the install it decided for; the keyboard, which must not wait
/// on StoreKit when it appears, logs only for that same install.
enum DebuggingVisibility {
  /// Known without asking StoreKit: a debug build or the Simulator always may.
  static var shownByBuild: Bool { debugBuild || simulator }

  /// This install: the path of the app bundle that holds `bundleURL` (the app's own, or its keyboard's inside
  /// PlugIns). iOS puts each installed build in a bundle container of its own, under a new random folder, so the
  /// App Store build that replaces a TestFlight one (the same binary) has a different path. That is observed iOS
  /// behaviour, not an Apple guarantee; a path that changes for another reason only stops the log until v2t is
  /// opened again.
  static func install(of bundleURL: URL) -> String? {
    var url = bundleURL.resolvingSymlinksInPath()  // one spelling of /var and /private/var for both processes
    while url.pathComponents.count > 1 {
      if url.pathExtension == "app" { return url.path }
      url.deleteLastPathComponent()
    }
    return nil
  }

  /// The keyboard's switch: when to stop the debug log if it may record now, nil to keep it off. The app's deadline
  /// must still be ahead, and outside a debug or Simulator build the app must have approved this very install; an
  /// install the app has not decided on yet (the App Store's, before v2t is opened) records nothing.
  static func keyboardLogUntil(settings: Settings, thisInstall: String?, shownByBuild: Bool = shownByBuild,
                               now: Date = Date()) -> Date? {
    guard let until = settings.keyboardDebugLogUntil, until > now else { return nil }
    if shownByBuild { return until }
    guard let thisInstall, settings.debuggingInstall == thisInstall else { return nil }
    return until
  }

  static var debugBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }

  static var simulator: Bool {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
  }
}
