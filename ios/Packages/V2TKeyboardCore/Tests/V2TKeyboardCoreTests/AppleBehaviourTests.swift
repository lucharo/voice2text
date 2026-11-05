import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Apple's keyboard autocorrect behaviour as a checklist (ios/AUTOCORRECT.md has each item's source), each
/// item checked against the engine with taps at the key centres. An item the engine does not do yet is a
/// known issue, so the suite stays green and the table shows the gap; a known issue that starts passing
/// fails the test, so the list cannot go stale.
///
/// Print the table: `swift test --filter AppleBehaviour 2>&1 | grep '^behaviour'`.
struct AppleBehaviour: CustomTestStringConvertible, Sendable {
  let id: String
  let behaviour: String
  /// The engine does not do this yet.
  let gap: Bool
  let check: @Sendable () throws -> Bool

  var testDescription: String { id }

  static let layout = KeyboardLayout(width: 402, language: .english)
  static let esLayout = KeyboardLayout(width: 402, language: .spanish)

  static func engine(_ start: String = "", spanish: Bool = false) throws -> (TypingEngine, FakeProxy) {
    let p = FakeProxy()
    p.text = start
    let lex = spanish ? try Fixtures.spanish.get() : try Fixtures.english.get()
    let e = TypingEngine(proxy: p, suggester: Suggester(lexicons: [lex], layout: spanish ? esLayout : layout))
    e.resync()
    return (e, p)
  }

  /// Types `s` key by key, a second apart (never a double tap): " " is space, "\n" return, "⌫" delete,
  /// anything else a key; letters at their key's centre, capitals as typed.
  static func type(_ s: String, _ e: TypingEngine, layout: KeyboardLayout = layout) {
    var t: TimeInterval = 1000
    for ch in s {
      t += 1
      switch ch {
      case " ": e.space(now: t)
      case "\n": e.returnKey()
      case "⌫": e.delete()
      default: e.character(String(ch), at: layout.keys.first { $0.label == String(ch).lowercased() }?.center, now: t)
      }
    }
  }

  /// `typed` after `start` gives `want`.
  static func types(_ typed: String, after start: String = "I said ", gives want: String, spanish: Bool = false) throws -> Bool {
    let (e, p) = try engine(start, spanish: spanish)
    type(typed, e, layout: spanish ? esLayout : layout)
    return p.text == start + want
  }

  static let all: [AppleBehaviour] = [
    // when a correction applies
    .init(id: "space-applies", behaviour: "Space applies the correction", gap: false) { try types("teh ", gives: "the ") },
    .init(id: "punctuation-applies", behaviour: "Punctuation applies the correction", gap: false) {
      try types("teh,", gives: "the,") && types("teh.", gives: "the.") && types("teh?", gives: "the?")
    },
    .init(id: "return-applies", behaviour: "Return applies the correction", gap: false) { try types("teh\n", gives: "the\n") },
    .init(id: "bar-shows-typed", behaviour: "The bar offers the word as typed beside the correction", gap: false) {
      let (e, _) = try engine("I said ")
      type("teh", e)
      let bar = e.suggestions().map(\.word)
      return bar.first == "teh" && bar.contains("the") && e.pendingAutocorrection == "the"
    },
    .init(id: "tap-typed-keeps", behaviour: "Tapping the typed word keeps it and learns it", gap: false) {
      let (e, p) = try engine("I said ")
      type("teh", e)
      e.pick("teh")
      type("teh ", e)
      return p.text == "I said teh teh " && e.learned.contains("teh")
    },
    // revert
    .init(id: "backspace-reverts", behaviour: "Backspace after a correction offers the original back", gap: false) {
      let (e, p) = try engine("I said ")
      type("teh ⌫", e)
      guard e.suggestions().first?.word == "teh" else { return false }
      e.pick("teh")
      return p.text == "I said teh "
    },
    .init(id: "reverted-not-recorrected", behaviour: "A reverted word is not corrected again", gap: false) {
      let (e, p) = try engine("I said ")
      type("teh ⌫", e)
      e.pick("teh")
      type("teh ", e)
      return p.text == "I said teh teh "
    },
    // contractions
    .init(id: "dont", behaviour: "dont becomes don't", gap: false) { try types("dont ", gives: "don't ") },
    .init(id: "im", behaviour: "im becomes I'm", gap: false) { try types("im ", gives: "I'm ") },
    .init(id: "youre", behaviour: "youre becomes you're", gap: false) { try types("youre ", gives: "you're ") },
    .init(id: "cant-wont", behaviour: "cant and wont (rare words) become can't and won't", gap: true) {
      try types("cant ", gives: "can't ") && types("wont ", gives: "won't ")
    },
    .init(id: "whats", behaviour: "whats becomes what's", gap: true) { try types("whats ", gives: "what's ") },
    .init(id: "ill-its-kept", behaviour: "ill, its, were, well, hell stay (common words), I'll and it's in the bar", gap: false) {
      for w in ["ill", "its", "were", "well", "hell"] where try !types(w + " ", gives: w + " ") { return false }
      let (e, _) = try engine("I said ")
      type("ill", e)
      let (f, _) = try engine("I said ")
      type("its", f)
      return e.suggestions().map(\.word).contains("I'll") && f.suggestions().map(\.word).contains("it's")
    },
    .init(id: "curly-apostrophe", behaviour: "A curly apostrophe typed in a word stays (don’t is not rewritten)", gap: false) {
      try types("don’t ", gives: "don’t ")
    },
    .init(id: "plural-possessive", behaviour: "A plural possessive keeps its apostrophe (parents')", gap: false) {
      try types("parents' ", after: "my ", gives: "parents' ")
    },
    .init(id: "lone-i", behaviour: "A lone i becomes I", gap: false) { try types("i ", after: "and ", gives: "I ") },
    .init(id: "i-contractions", behaviour: "i'm, i'll, i'd become I'm, I'll, I'd", gap: true) {
      try types("i'm ", after: "and ", gives: "I'm ") && types("i'll ", after: "and ", gives: "I'll ") && types("i'd ", after: "and ", gives: "I'd ")
    },
    // what is left alone
    .init(id: "capitalised-mid-sentence", behaviour: "A capitalised word mid-sentence is not turned into a common word (a known name is fixed)", gap: false) {
      try types("Figma ", after: "I use ", gives: "Figma ") && types("Britian ", after: "I live in ", gives: "Britain ")
    },
    .init(id: "url", behaviour: "A web address is not corrected", gap: true) {
      try types("www.exmaple.cmo ", after: "see ", gives: "www.exmaple.cmo ") && types("exmaple.com/teh ", after: "see ", gives: "exmaple.com/teh ")
    },
    .init(id: "email", behaviour: "An email address is not corrected", gap: true) {
      try types("jhon@gmial.com ", after: "write to ", gives: "jhon@gmial.com ")
    },
    .init(id: "handle-hashtag", behaviour: "An @handle or #hashtag is not corrected", gap: true) {
      try types("@jhon ", after: "ping ", gives: "@jhon ") && types("#teh ", after: "tag ", gives: "#teh ")
    },
    .init(id: "numbers", behaviour: "Words with digits are not corrected", gap: false) {
      try types("10am ", gives: "10am ") && types("2nd ", gives: "2nd ") && types("teh2 ", gives: "teh2 ")
    },
    .init(id: "user-dictionary", behaviour: "A word in the user's dictionary is not corrected", gap: false) {
      let (e, p) = try engine("I use ")
      e.learned.insert("fluide")
      type("fluide ", e)
      return p.text == "I use fluide "
    },
    .init(id: "text-replacement", behaviour: "A text replacement (omw → On my way!) expands at the end of the word", gap: true) {
      let (e, p) = try engine("ok ")
      e.replacements = ["omw": "On my way!"]
      type("omw ", e)
      return p.text == "ok On my way! "
    },
    .init(id: "real-word-kept", behaviour: "A real word is never replaced by a near one (form, from)", gap: false) {
      try types("form ", gives: "form ") && types("from ", gives: "from ")
    },
    .init(id: "single-letter", behaviour: "A single letter other than i is left alone", gap: false) {
      try types("u ", gives: "u ") && types("x ", gives: "x ")
    },
    .init(id: "keeps-capitals", behaviour: "A correction keeps the typed capitals (Teh → The, TEH → THE)", gap: false) {
      try types("Teh ", after: "", gives: "The ") && types("TEH ", after: "ok ", gives: "THE ")
    },
    // punctuation and capitals
    .init(id: "double-space", behaviour: "Double space after a word types a full stop and a space", gap: false) {
      let (e, p) = try engine("Hi ")
      type("there", e)
      e.space(now: 5000)
      e.space(now: 5000.2)
      let (f, q) = try engine("Hi, ")
      f.space(now: 5000.2)
      return p.text == "Hi there. " && e.shift == .on && q.text == "Hi,  "
    },
    .init(id: "auto-capitals", behaviour: "Capitals after . ! ? and a new line", gap: false) {
      let (e, p) = try engine()
      type("hi. ok! why? fine\nyes", e)
      return p.text == "Hi. Ok! Why? Fine\nYes"
    },
    // Spanish
    .init(id: "es-accents", behaviour: "Spanish: a missing accent is restored (cancion → canción), real words stay (como)", gap: false) {
      try types("cancion ", after: "una ", gives: "canción ", spanish: true) && types("como ", after: "y ", gives: "como ", spanish: true)
    },
    .init(id: "es-rare-variant", behaviour: "Spanish: ano and anos (rare words) become año and años", gap: true) {
      try types("ano ", after: "este ", gives: "año ", spanish: true) && types("anos ", after: "dos ", gives: "años ", spanish: true)
    },
  ]
}

struct AppleBehaviourTests {
  @Test(arguments: AppleBehaviour.all)
  func appleBehaviour(_ item: AppleBehaviour) throws {
    let ok = try item.check()
    print("behaviour | \(item.id) | \(item.behaviour) | \(ok ? "pass" : "FAIL")")
    if item.gap {
      withKnownIssue("not done yet: \(item.behaviour)") { #expect(ok) }
    } else {
      #expect(ok, "\(item.behaviour)")
    }
  }
}
