import StoreKit

/// The app's half of `DebuggingVisibility`: which build this is, and recording the answer for the keyboard.
extension DebuggingVisibility {
  /// What this install says about where it came from. Two signals, because either can be missing: build 130 read
  /// StoreKit alone, got no answer on a TestFlight install, and hid Debugging there.
  struct Build: Equatable {
    /// The App Store server environment that signed this install, nil when StoreKit gave no app transaction.
    var environment: AppStore.Environment?
    /// The file name of the App Store receipt's URL, nil when the bundle names none.
    var receipt: String?
    var debugBuild = false
    var simulator = false

    /// The receipt's file name in a TestFlight or development-signed build; an App Store install's is `receipt`.
    /// Long-observed iOS behaviour rather than an Apple guarantee, which is why it is one signal of two.
    static let sandboxReceipt = "sandboxReceipt"
    static let storeReceipt = "receipt"

    /// Either signal naming the sandbox. Apple: "Apps in the development and beta-testing stages of your product
    /// cycle use the sandbox environment for Apple In-App Purchases. These apps include: … Apps you download from
    /// TestFlight" (https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox), and
    /// `AppTransaction.environment` is "The server environment that signs the app transaction."
    /// (https://developer.apple.com/documentation/storekit/apptransaction/environment). `.xcode` is StoreKit Testing.
    var saysTestFlight: Bool {
      receipt == Build.sandboxReceipt || environment == .sandbox || environment == .xcode
    }

    /// The rule. Debugging shows on evidence of a TestFlight build from either signal, and in debug and Simulator
    /// builds; with no such evidence it is hidden, so an App Store build never shows it by a failed read.
    var showsDebugging: Bool { debugBuild || simulator || saysTestFlight }

    /// The build type in words, for the line under About v2t. When neither signal settles it, the line carries what
    /// each one said, so a phone where Debugging is missing shows why.
    var label: String {
      if debugBuild { return "debug build" }
      if simulator { return "Simulator" }
      if saysTestFlight { return "TestFlight" }
      if environment == .production && receipt == Build.storeReceipt { return "App Store" }
      let store = environment.map { $0.rawValue } ?? "no answer"
      return "build type unsure (StoreKit: \(store), receipt: \(receipt ?? "none"))"
    }
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

  /// What is known without waiting: the build flags and the receipt's name.
  static var buildAtLaunch: Build {
    Build(environment: nil, receipt: (Bundle.main as ReceiptNaming).receiptName,
          debugBuild: debugBuild, simulator: simulator)
  }

  /// This install, once StoreKit has answered or declined to. An unverified app transaction still names its
  /// environment, which is enough to decide whether to show a debugging section.
  static func current() async -> Build {
    var build = buildAtLaunch
    if let result = try? await AppTransaction.shared {
      switch result {
      case .verified(let t), .unverified(let t, _): build.environment = t.environment
      }
    }
    return build
  }
}

/// `Bundle.appStoreReceiptURL` is deprecated in iOS 18 in favour of `AppTransaction`, which is the signal that went
/// missing; reading it through a protocol keeps the deprecation out of every build's warnings.
private protocol ReceiptNaming {
  var receiptName: String? { get }
}

extension Bundle: ReceiptNaming {
  @available(iOS, deprecated: 18.0)
  fileprivate var receiptName: String? { appStoreReceiptURL?.lastPathComponent }
}
