import V2TKeyboardCore

/// The typing exercise's sentences. Ours, written for v2t, not taken from any source: everyday messages under
/// about 60 characters that together use every letter several times, with common contractions, a few names to
/// capitalise, and words that sit next to each other on the keyboard or differ by one letter (form and from,
/// were and where, quite and quiet, hat and had). The Spanish ones carry accents and ñ.
enum ExerciseSentences {
  struct Sentence: Equatable, Sendable {
    let id: String
    let text: String
  }

  static let english: [Sentence] = [
    "Can you grab some milk on the way home?",
    "I'm running ten minutes late, sorry!",
    "Did you see the email from Priya?",
    "We were going to meet where the bus stops.",
    "That's quite a quiet street for a Friday.",
    "Let's book the table for six, not seven.",
    "Jake said the jazz night was fun.",
    "Don't forget your keys and the blue jacket.",
    "Could you text me when you've landed?",
    "The quiz starts at eight, so be quick.",
    "I'd rather walk than wait for a taxi.",
    "She's back from Lisbon on Wednesday.",
    "My phone died, I'll call you later.",
    "We had a hat for him but he lost it.",
    "Is the form ready or should I fix it?",
    "Maybe we can swap shifts next week.",
    "He won't mind if we bring the dog.",
    "Thanks for the pizza, it was amazing.",
    "Just a quick check, is Zoe coming too?",
    "Sit by the window, the view is lovely.",
    "Your box arrived, I left it by the door.",
    "It's cold out, take a warm jumper.",
    "We'll grab a coffee after the gym.",
    "Mark the vote as yes and pass it back.",
  ].enumerated().map { Sentence(id: String(format: "en-%02d", $0.offset + 1), text: $0.element) }

  static let spanish: [Sentence] = [
    "Quedamos mañana a las ocho en la plaza.",
    "¿Te paso a buscar después de clase?",
    "Mi año empezó con un viaje a Sevilla.",
    "No sé si llegaré a tiempo, lo siento.",
    "Gracias por el café, estaba buenísimo.",
    "La niña quiere jugar en el jardín.",
    "Ya compré pan, leche y algo de fruta.",
    "Está lloviendo, coge el paraguas.",
  ].enumerated().map { Sentence(id: String(format: "es-%02d", $0.offset + 1), text: $0.element) }

  /// Sentences in one exercise.
  static let perExercise = 10
  /// Of those, the Spanish ones when Spanish is among the suggestion languages.
  static let spanishPerExercise = 3

  /// One exercise's sentences in a shuffled order: English, with a few Spanish ones mixed in when Spanish words
  /// are suggested too.
  static func pick(languages: [KeyboardLanguage], using rng: inout some RandomNumberGenerator) -> [Sentence] {
    let es = languages.contains(.spanish) ? spanishPerExercise : 0
    let chosen = Array(english.shuffled(using: &rng).prefix(perExercise - es)) + Array(spanish.shuffled(using: &rng).prefix(es))
    return chosen.shuffled(using: &rng)
  }
}
