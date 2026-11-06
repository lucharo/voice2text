import Foundation
import V2TKeyboardCore

/// Settings shared by the app and the keyboard through the App Group. The keyboard can read them always,
/// and write them only with Full Access.
enum MicrophoneChoice: String, CaseIterable, Sendable {
  case iPhone = "iphone"
  /// Wired headphones, a USB mic or AirPods when one is connected; the iPhone's otherwise.
  case connected
}

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

  /// Which microphone dictation records from. The iPhone's own by default, so AirPods keep playing music in
  /// high quality; a connected headset's or AirPods' mic turns Bluetooth headphones into a call headset.
  var microphoneChoice: MicrophoneChoice {
    get { MicrophoneChoice(rawValue: defaults.string(forKey: "microphoneChoice") ?? "") ?? .iPhone }
    set { defaults.set(newValue.rawValue, forKey: "microphoneChoice") }
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

  /// Apple Intelligence tidies each dictation when this is on and the model is available.
  var cleanupEnabled: Bool {
    get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "cleanupEnabled") }
  }
}
