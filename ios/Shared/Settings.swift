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

  var cleanupEnabled: Bool {
    get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "cleanupEnabled") }
  }
}
