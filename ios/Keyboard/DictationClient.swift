import UIKit

/// The keyboard's side of dictation. With a warm session in the app, the mic key records in place; without
/// one, it opens the v2t app once (the only route iOS leaves a keyboard), which starts the session and
/// sends the user back.
@MainActor final class DictationClient {
  private weak var controller: UIInputViewController?
  private let defaults = Settings.shared.defaults
  private var observer: DarwinObserver?
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
    observer = DictationChannel.observe(DictationChannel.changed) { [weak self] in self?.changed() }
    changed()  // a result that finished while the keyboard was away (the user was in the v2t app)
  }

  func detach() { observer = nil }

  func toggle() {
    switch state {
    case .idle:
      newRequest()
      DictationChannel.post(DictationChannel.start)
    case .listening:
      stampDocument()  // the field the user is in when they stop is where the text goes
      DictationChannel.post(DictationChannel.stop)
    case .needsApp:
      newRequest()
      openApp()
    case .transcribing, .unavailable:
      break
    }
    onState?(state)
  }

  private func newRequest() {
    defaults.set(UUID().uuidString, forKey: DictationChannel.requestIdKey)
    stampDocument()
  }

  private var document: String { controller?.textDocumentProxy.documentIdentifier.uuidString ?? "" }

  private func stampDocument() { defaults.set(document, forKey: DictationChannel.requestDocumentKey) }

  /// Types the result once, and only the answer to the latest request.
  private func changed() {
    onState?(state)
    let id = defaults.string(forKey: DictationChannel.resultIdKey) ?? ""
    guard !id.isEmpty, id == defaults.string(forKey: DictationChannel.requestIdKey),
          id != defaults.string(forKey: DictationChannel.deliveredIdKey),
          let text = defaults.string(forKey: DictationChannel.resultKey), !text.isEmpty else { return }
    // another field (this or a later keyboard): leave it untyped; it is in History
    guard document == defaults.string(forKey: DictationChannel.requestDocumentKey) else { return }
    defaults.set(id, forKey: DictationChannel.deliveredIdKey)
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
