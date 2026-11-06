import Foundation
import V2TKeyboardCore

/// Settings shared by the app and the keyboard through the App Group. The keyboard can read them always,
/// and write them only with Full Access.
final class Settings: @unchecked Sendable {
  static let group = "group.es.luischav.v2t"
  static let shared = Settings()
  let defaults: UserDefaults

  init(defaults: UserDefaults? = UserDefaults(suiteName: Settings.group)) {
    self.defaults = defaults ?? .standard
  }

  var layoutLanguage: KeyboardLanguage {
    get { KeyboardLanguage(rawValue: defaults.string(forKey: "layoutLanguage") ?? "") ?? .english }
    set { defaults.set(newValue.rawValue, forKey: "layoutLanguage") }
  }

  /// Languages whose words are suggested and corrected together (bilingual typing).
  var suggestionLanguages: [KeyboardLanguage] {
    get { (defaults.stringArray(forKey: "suggestionLanguages") ?? ["en", "es"]).compactMap(KeyboardLanguage.init(rawValue:)) }
    set { defaults.set(newValue.map(\.rawValue), forKey: "suggestionLanguages") }
  }

  var learnedWords: Set<String> { Set(defaults.stringArray(forKey: "learnedWords") ?? []) }

  func learn(_ word: String) {
    var w = learnedWords
    w.insert(word)
    defaults.set(Array(w).sorted(), forKey: "learnedWords")
  }

  /// Minutes the mic stays warm after the last dictation (0 = until turned off).
  var warmMinutes: Int {
    get { defaults.object(forKey: "warmMinutes") as? Int ?? 15 }
    set { defaults.set(newValue, forKey: "warmMinutes") }
  }

  /// Speech language for transcription: "en", "es" or "auto".
  var speechLanguage: String {
    get { defaults.string(forKey: "speechLanguage") ?? "en" }
    set { defaults.set(newValue, forKey: "speechLanguage") }
  }

  /// When the keyboard last opened with Full Access. iOS gives an app no public way to ask whether its
  /// keyboard is added or has Full Access, and a keyboard without Full Access cannot write to the App
  /// Group, so this is the only signal: set means both setup steps were done at least once.
  var keyboardFullAccessSeen: Date? {
    get { (defaults.object(forKey: "keyboardFullAccessSeen") as? Double).map(Date.init(timeIntervalSince1970:)) }
    set { defaults.set(newValue?.timeIntervalSince1970, forKey: "keyboardFullAccessSeen") }
  }

  /// UI tests only: the keyboard shows its recording view in this state ("listening" or "transcribing") with
  /// a made-up waveform, without a microphone session or Full Access. The app clears it on every launch.
  var previewRecording: String? {
    get { defaults.string(forKey: "previewRecording") }
    set { defaults.set(newValue, forKey: "previewRecording") }
  }

  /// UI tests only: the keyboard draws its own globe key (true) or not (false) whatever iOS asks for, so a
  /// Face ID Simulator can show the Touch ID iPhone's bottom row. The app clears it on every launch.
  var previewGlobeKey: Bool? {
    get { defaults.object(forKey: "previewGlobeKey") as? Bool }
    set { defaults.set(newValue, forKey: "previewGlobeKey") }
  }

  /// UI tests only: how the keyboard draws its mic key ("A", "B", "C", or "C-warm" for C with the mic session
  /// on), so each style can be screenshotted. The app clears it on every launch.
  var previewMicStyle: String? {
    get { defaults.string(forKey: "previewMicStyle") }
    set { defaults.set(newValue, forKey: "previewMicStyle") }
  }

  /// Apple Intelligence tidies each dictation when this is on and the model is available.
  var cleanupEnabled: Bool {
    get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "cleanupEnabled") }
  }
}
