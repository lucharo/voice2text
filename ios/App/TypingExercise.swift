import SwiftUI
import V2TKeyboardCore

/// One run of the typing exercise: which sentence is showing, when it appeared, and what was typed for the ones
/// before it. Each sentence finished goes to `exercises.jsonl` beside the keyboard debug log
/// (`TypingExerciseLog`), on the log's clock, while the log is on.
@MainActor final class TypingExerciseSession: ObservableObject {
  struct Done: Equatable {
    let sentence: ExerciseSentences.Sentence
    let typed: String
    /// Seconds from the first change to the field to Next.
    let seconds: TimeInterval
  }

  let sentences: [ExerciseSentences.Sentence]
  @Published private(set) var index = 0
  @Published private(set) var done: [Done] = []
  /// The field's text. Its first change after a sentence appears starts that sentence's typing time; Next clears it
  /// before the next sentence's time is reset, so the clear is not counted as typing.
  @Published var text = "" {
    didSet { if firstEdit == nil, text != oldValue { firstEdit = clock() } }
  }
  private let directory: URL?
  private let clock: @Sendable () -> TimeInterval
  private let now: () -> Date
  private let recording: () -> Bool
  private var shownAt: TimeInterval = 0
  private var shownWall = Date()
  private var firstEdit: TimeInterval?

  init(sentences: [ExerciseSentences.Sentence], directory: URL? = KeyboardLogStore.groupDirectory,
       clock: @escaping @Sendable () -> TimeInterval = KeyboardDebugLog.systemClock, now: @escaping () -> Date = Date.init,
       recording: @escaping () -> Bool = { KeyboardLogSection.activeUntil != nil }) {
    self.sentences = sentences
    self.directory = directory
    self.clock = clock
    self.now = now
    self.recording = recording
  }

  var current: ExerciseSentences.Sentence? { index < sentences.count ? sentences[index] : nil }
  var finished: Bool { current == nil }

  /// The current sentence is on screen: its time starts now.
  func shown() {
    shownAt = clock()
    shownWall = now()
    firstEdit = nil
  }

  /// Next: records what the field holds, clears it and moves on to the next sentence, if there is one.
  func next() {
    guard let sentence = current else { return }
    let end = clock(), typed = text
    if recording(), let directory {
      TypingExerciseLog.append(.init(id: sentence.id, target: sentence.text, typed: typed, start: shownAt, end: end, wall: shownWall), in: directory)
    }
    done.append(Done(sentence: sentence, typed: typed, seconds: firstEdit.map { end - $0 } ?? 0))
    index += 1
    text = ""
    if !finished { shown() }
  }

  /// The words that ended up different from their sentence, in order.
  var wrongWords: [(target: String, typed: String)] {
    done.flatMap { TypingExerciseLog.wrongWords(target: $0.sentence.text, typed: $0.typed) }
  }

  /// Characters in the finished text per second of typing, nil before any typing time.
  var charactersPerSecond: Double? {
    let seconds = done.map(\.seconds).reduce(0, +)
    return seconds > 0 ? Double(done.map(\.typed.count).reduce(0, +)) / seconds : nil
  }
}

/// Debugging › Typing exercise: shows a sentence at a time to type with the v2t keyboard, as a typing test, so the
/// keyboard debug log holds what was meant next to every touch. A summary follows the last sentence.
struct TypingExerciseView: View {
  @StateObject private var session = TypingExerciseView.newSession()
  /// The one line about the debug log, shown before the first sentence.
  @State private var logNote: String?
  @FocusState private var focused: Bool

  /// UI tests pick the languages (V2T_EXERCISE_LANGUAGES, "en" or "en,es"); otherwise the keyboard's suggestion
  /// languages.
  static func newSession() -> TypingExerciseSession {
    let env = ProcessInfo.processInfo.environment["V2T_EXERCISE_LANGUAGES"]
    let languages = env.map { $0.split(separator: ",").compactMap { KeyboardLanguage(rawValue: String($0)) } } ?? Settings.shared.suggestionLanguages
    var rng = SystemRandomNumberGenerator()
    return TypingExerciseSession(sentences: ExerciseSentences.pick(languages: languages, using: &rng))
  }

  var body: some View {
    Group {
      if let sentence = session.current {
        exercise(sentence)
      } else {
        summary
      }
    }
    .navigationTitle("Typing exercise")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func exercise(_ sentence: ExerciseSentences.Sentence) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if session.index == 0, let logNote {
          Text(logNote).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("v2t.exercise.logNote")
        }
        Text("Sentence \(session.index + 1) of \(session.sentences.count)")
          .font(.subheadline).foregroundStyle(.secondary)
          .accessibilityIdentifier("v2t.exercise.progress")
        Text(sentence.text)
          .font(.title2)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Type: \(sentence.text)")
          .accessibilityIdentifier("v2t.exercise.sentence")
        // a plain message field: its traits stay iOS's defaults, so the v2t keyboard corrects as it always does
        TextField("Type the sentence here", text: $session.text)
          .textFieldStyle(.roundedBorder)
          .focused($focused)
          .onSubmit(next)
          .accessibilityIdentifier("v2t.exercise.field")
        Button(action: next) {
          Text(session.index + 1 == session.sentences.count ? "Finish" : "Next").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(session.text.isEmpty)
        .accessibilityIdentifier("v2t.exercise.next")
      }
      .padding()
    }
    .scrollDismissesKeyboard(.never)
    .onAppear {
      // the log is on before the field brings the keyboard up: the keyboard reads the switch as it appears
      turnOnLog()
      session.shown()
      focused = true
    }
  }

  private var summary: some View {
    let wrong = session.wrongWords
    return List {
      Section {
        LabeledContent("Sentences", value: "\(session.done.count)")
          .accessibilityIdentifier("v2t.exercise.sentencesDone")
        LabeledContent("Words different from the sentence", value: "\(wrong.count)")
          .accessibilityIdentifier("v2t.exercise.wrongCount")
        LabeledContent("Characters per second", value: session.charactersPerSecond.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
          .accessibilityIdentifier("v2t.exercise.speed")
      } footer: {
        Text("Each sentence is in the keyboard debug log beside what the keyboard recorded. Export it from Debugging.")
      }
      if !wrong.isEmpty {
        Section("Different words") {
          ForEach(Array(wrong.enumerated()), id: \.offset) { _, w in
            VStack(alignment: .leading, spacing: 2) {
              Text(w.target)
              Text(w.typed.isEmpty ? "Nothing typed" : w.typed).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(w.target), typed as \(w.typed.isEmpty ? "nothing" : w.typed)")
          }
        }
      }
    }
    .accessibilityIdentifier("v2t.exercise.summary")
  }

  private func next() {
    guard !session.text.isEmpty, !session.finished else { return }
    session.next()
    if session.finished { focused = false }
  }

  /// The exercise is for the debug log: it turns it on for its 24 hours if it is off, and says so.
  private func turnOnLog() {
    guard logNote == nil else { return }
    if let until = KeyboardLogSection.activeUntil {
      logNote = "The keyboard debug log is on until \(until.formatted(date: .abbreviated, time: .shortened)) and records this exercise."
    } else {
      Settings.shared.keyboardDebugLogUntil = Date().addingTimeInterval(KeyboardLogStore.lifetime)
      logNote = "The keyboard debug log is now on for 24 hours, to record this exercise."
    }
  }
}
