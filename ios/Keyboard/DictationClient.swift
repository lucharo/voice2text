import UIKit

/// The keyboard's side of dictation. With a warm session in the app, the mic key records in place; without
/// one, it opens the v2t app once (the only route iOS leaves a keyboard), which starts the session and
/// sends the user back.
@MainActor final class DictationClient {
  private weak var controller: UIInputViewController?
  private let defaults = Settings.shared.defaults
  private var observer: DarwinObserver?
  private var lastResultId = ""
  var onText: ((String) -> Void)?
  var onState: ((DictationState) -> Void)?

  init(controller: UIInputViewController) { self.controller = controller }

  var state: DictationState {
    guard controller?.hasFullAccess == true else { return .unavailable }
    let beat = defaults.double(forKey: DictationChannel.heartbeatKey)
    guard Date().timeIntervalSince1970 - beat < DictationChannel.heartbeatTimeout else { return .needsApp }
    return DictationState(rawValue: defaults.string(forKey: DictationChannel.stateKey) ?? "") ?? .needsApp
  }

  func attach() {
    lastResultId = defaults.string(forKey: DictationChannel.resultIdKey) ?? ""
    observer = DictationChannel.observe(DictationChannel.changed) { [weak self] in self?.changed() }
    onState?(state)
  }

  func detach() { observer = nil }

  func toggle() {
    switch state {
    case .idle:
      defaults.set(UUID().uuidString, forKey: DictationChannel.requestIdKey)
      DictationChannel.post(DictationChannel.start)
    case .listening:
      DictationChannel.post(DictationChannel.stop)
    case .needsApp:
      openApp()
    case .transcribing, .unavailable:
      break
    }
    onState?(state)
  }

  private func changed() {
    onState?(state)
    let id = defaults.string(forKey: DictationChannel.resultIdKey) ?? ""
    guard id != lastResultId, let text = defaults.string(forKey: DictationChannel.resultKey), !text.isEmpty else { return }
    lastResultId = id
    onText?(text)
  }

  /// Keyboards have no public way to open their app (NSExtensionContext.open is for Today and iMessage
  /// extensions, and UIApplication.open is unavailable to extensions). Like other dictation keyboards, we
  /// find the UIApplication in the responder chain and send it openURL:options:completionHandler:.
  private func openApp() {
    typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
    let sel = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = controller
    while let r = responder {
      if r.isKind(of: UIApplication.self), r.responds(to: sel) {
        let fn = unsafeBitCast(r.method(for: sel), to: OpenFn.self)
        fn(r, sel, DictationChannel.url as NSURL, [:] as NSDictionary, nil)
        return
      }
      responder = r.next
    }
  }
}
