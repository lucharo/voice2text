import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Offline quality evaluation of swipe typing and the suggestion bar, against words people actually type
/// (not the lexicon's own top list), with the iPhone 17 Pro layout (402 pt) and English and Spanish both on,
/// as on the owner's phone. Prints a table; the floors below guard against regressions.
///
/// Print the table: `swift test --filter QualityEval 2>&1 | grep '^eval'`.
enum QualityEval {
  /// Whitespace-separated words, first occurrence kept.
  static func wordList(_ s: String) -> [String] {
    var seen = Set<String>()
    return s.split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0).inserted }
  }

  /// About 300 of the commonest English words in everyday writing and chat, two letters or more.
  static let english = wordList("""
    the be to of and in that have it for not on with he as you do at this but his by from they we say her she or
    an will my one all would there their what so up out if about who get which go me when make can like time no
    just him know take people into year your good some could them see other than then now look only come its over
    think also back after use two how our work first well way even new want because any these give day most us is
    are was were been has had did said going got thing things really very much more here why where yeah okay hey
    thanks thank please sorry hello love need feel tell let call try ask put mean keep still should never always
    something anything nothing everything someone maybe today tomorrow tonight morning night week home house
    friend friends family man woman life world school right left long little great big old high small next last
    own same different important help show hear play run move live believe hold bring happen write sit stand lose
    pay meet include continue set learn change lead understand watch follow stop create speak read spend grow open
    walk win offer remember buy wait send expect build stay fall cut reach remain pass sell decide pull talk
    start turn leave find went came made told asked done gone seen took gave knew thought felt left kind sure
    nice fine happy best better bad hard easy real free full whole every each few many lot again ever away down
    off too yes yet already almost around before between during under while until since though through across
    without against city car food water money book phone game music party dinner lunch coffee work job office
    place name word idea point problem question answer number part side hand head face eye eyes mind story fact
    month weekend minute hour hours later soon early late cool awesome amazing funny weird crazy tired busy ready
    excited guess hope wish miss mom dad baby kids girl boy guy guys team class plan picture video message text
    email meeting
    """)

  /// About 100 common Spanish words, accents included.
  static let spanish = wordList("""
    de la que el en los se del las un por con no una su para es al lo como más pero sus le ya este sí porque esta
    entre cuando muy sin sobre también me hasta hay donde quien desde todo nos todos uno les ni otros ese eso ante
    ellos esto antes algunos qué unos yo otro otra él tanto esa estos mucho nada muchos poco ella estar algo mi
    hola gracias bien bueno buenos días noche mañana tarde casa tiempo vida mundo año hoy ahora siempre nunca
    después mejor quiero puedo tengo hacer tener ser voy vamos creo hablar comer trabajo amigo amigos familia gente
    cosa cosas aquí dónde cómo nuevo grande favor claro vale adiós señor niño español canción
    """)

  /// Next words people expect after a common word.
  static let englishPairs: [(String, String)] = [
    ("how", "are"), ("thank", "you"), ("i", "am"), ("going", "to"), ("do", "you"), ("see", "you"), ("i", "think"),
    ("let", "me"), ("on", "the"), ("in", "the"), ("want", "to"), ("have", "a"), ("it", "is"), ("are", "you"),
    ("what", "is"), ("i", "will"), ("good", "morning"), ("talk", "to"), ("of", "the"), ("you", "are"),
    ("i", "have"), ("i", "was"), ("can", "you"), ("need", "to"), ("at", "the"), ("to", "be"), ("will", "be"),
    ("this", "is"), ("for", "the"), ("love", "you"),
  ]
  static let spanishPairs: [(String, String)] = [
    ("de", "la"), ("por", "favor"), ("muchas", "gracias"), ("buenos", "días"), ("en", "el"), ("lo", "que"),
    ("que", "no"), ("me", "gusta"), ("a", "la"), ("no", "sé"), ("hasta", "luego"), ("buenas", "noches"),
    ("para", "el"), ("es", "un"), ("qué", "tal"), ("con", "el"), ("todo", "el"), ("te", "quiero"), ("de", "los"),
    ("estoy", "bien"),
  ]

  // MARK: a finger-like trace

  /// A swipe as a finger draws it: one offset for the whole trace (where this person's finger lands relative to
  /// the key they aim at), each key aimed at with its own scatter, the corners cut short (Chaikin's corner
  /// cutting with a random cut), and touch samples every 3 to 6 pt with half a point of sensor noise.
  /// All spreads are in key widths.
  static func fingerTrace(_ word: String, layout: KeyboardLayout, rng: inout SeededRandom,
                          scatter: Double = 0.22, bias: Double = 0.12) -> [CGPoint]? {
    var centers: [Character: CGPoint] = [:]
    for k in layout.keys { if case .character(let c) = k.action, let ch = c.first, c.count == 1 { centers[ch] = k.center } }
    let u = Double(layout.unitWidth)
    let off = CGPoint(x: rng.gaussian() * bias * u, y: rng.gaussian() * bias * u)
    var anchors: [CGPoint] = []
    var lastKey: CGPoint?
    for ch in word.lowercased() {
      guard let c = centers[ch] ?? String(ch).decomposedStringWithCanonicalMapping.unicodeScalars.first.flatMap({ centers[Character($0)] }) else { return nil }
      if c == lastKey { continue }  // a doubled letter is one visit
      lastKey = c
      anchors.append(CGPoint(x: c.x + off.x + CGFloat(rng.gaussian() * scatter * u), y: c.y + off.y + CGFloat(rng.gaussian() * scatter * u)))
    }
    guard anchors.count >= 2 else { return nil }
    // corner cutting: replace each interior corner by two points `cut` of the way along its two segments, but
    // never more than half a key from the key: a finger rounds a turn, it does not skip the key
    let cut = CGFloat(0.1 + 0.2 * Double.random(in: 0..<1, using: &rng))
    var path = [anchors[0]]
    for i in 1..<anchors.count - 1 {
      let a = anchors[i - 1], b = anchors[i], c = anchors[i + 1]
      let ca = min(cut, 0.5 * CGFloat(u) / max(hypot(a.x - b.x, a.y - b.y), 1)), cc = min(cut, 0.5 * CGFloat(u) / max(hypot(c.x - b.x, c.y - b.y), 1))
      path.append(CGPoint(x: b.x + (a.x - b.x) * ca, y: b.y + (a.y - b.y) * ca))
      path.append(CGPoint(x: b.x + (c.x - b.x) * cc, y: b.y + (c.y - b.y) * cc))
    }
    path.append(anchors[anchors.count - 1])
    var out = [path[0]]
    for i in 1..<path.count {
      let a = path[i - 1], b = path[i]
      let len = hypot(b.x - a.x, b.y - a.y)
      let step = CGFloat(3 + 3 * Double.random(in: 0..<1, using: &rng))
      let n = max(1, Int(len / step))
      for s in 1...n {
        let t = CGFloat(s) / CGFloat(n)
        out.append(CGPoint(x: a.x + (b.x - a.x) * t + CGFloat(rng.gaussian() * 0.5), y: a.y + (b.y - a.y) * t + CGFloat(rng.gaussian() * 0.5)))
      }
    }
    return out
  }

  /// Short messages, swiped a word at a time with the words before as context.
  static let englishSentences = [
    "hey how is it going", "thank you so much for your help", "i am going to be late today",
    "do you want to get dinner tonight", "what time is the meeting tomorrow", "i think we should talk about it",
    "can you send me the file", "let me know when you get home", "see you in the morning", "i love you",
    "i do not know what to do", "are you coming to the party", "it was really nice to meet you",
    "we need to buy some milk", "have a good weekend", "sorry i missed your call", "i will call you back later",
    "how was your day", "that sounds like a great idea", "where are you right now",
  ]
  static let spanishSentences = [
    "hola qué tal estás", "muchas gracias por todo", "nos vemos mañana por la tarde", "te quiero mucho",
    "no sé qué hacer", "buenos días a todos", "dónde estás ahora", "voy a llegar tarde",
    "me gusta mucho la música", "tengo que trabajar hoy",
  ]

  // MARK: measurements

  /// Knobs the tuning sweep turns; nil keeps the shipped default.
  struct Config {
    var frequencyWeight: Double?
    var properNounPenalty: Double?
    var acronymPenalty: Double?
    var otherLanguage: Double?
    var languageCap: Double?
    var swipeBigram: Double?
    var suggestFrequency: Double?
    var suggestBigram: Double?
    var suggestAcronym: Double?
    var alternativeMargin: Double?
    var minCompletionPrefix: Double?
    var completionLead: Double?

    func apply(_ d: SwipeDecoder) {
      if let v = frequencyWeight { d.frequencyWeight = v }
      if let v = properNounPenalty { d.properNounPenalty = v }
      if let v = acronymPenalty { d.acronymPenalty = v }
    }
    func multi(_ decoders: [SwipeDecoder]) -> MultiSwipeDecoder {
      decoders.forEach(apply)
      var m = MultiSwipeDecoder(decoders)
      if let v = otherLanguage { m.languagePrior.otherLanguage = v }
      if let v = languageCap { m.languagePrior.cap = v }
      if let v = swipeBigram { m.bigramWeight = v }
      if let v = alternativeMargin { m.alternativeMargin = v }
      return m
    }
    func suggester(_ lexicons: [Lexicon], _ layout: KeyboardLayout) -> Suggester {
      let s = Suggester(lexicons: lexicons, layout: layout)
      if let v = otherLanguage { s.languagePrior.otherLanguage = v }
      if let v = languageCap { s.languagePrior.cap = v }
      if let v = suggestFrequency { s.frequencyWeight = v }
      if let v = suggestBigram { s.bigramWeight = v }
      if let v = suggestAcronym { s.acronymPenalty = v }
      if let v = minCompletionPrefix { s.minCompletionPrefix = Int(v) }
      if let v = completionLead { s.completionLead = v }
      return s
    }
  }

  struct Row { var name: String; var hit1 = 0, hit4 = 0, total = 0; var misses: [String] = [] }

  static func trace(_ w: String, _ layout: KeyboardLayout, _ rng: inout SeededRandom, sloppy: Bool) -> [CGPoint]? {
    sloppy ? fingerTrace(w, layout: layout, rng: &rng, scatter: 0.3, bias: 0.3) : fingerTrace(w, layout: layout, rng: &rng)
  }

  static func count(_ row: inout Row, _ want: String, _ got: [String], _ label: String) {
    row.total += 1
    if got.first == want { row.hit1 += 1 } else if row.misses.count < 30 { row.misses.append("\(label)->\(got.first ?? "-")") }
    if got.prefix(4).contains(want) { row.hit4 += 1 }
  }

  /// Swipes of each word on its own (no words before it); top-1 is the word typed, top-4 includes the bar.
  static func swipeRow(_ name: String, words: [String], layout: KeyboardLayout, lexicons: [Lexicon], context: String = "",
                       trials: Int = 3, seed: UInt64 = 11, sloppy: Bool = false, config: Config = Config()) -> Row {
    let m = config.multi(lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) })
    var rng = SeededRandom(state: seed)
    var row = Row(name: name)
    for w in words {
      for _ in 0..<trials {
        guard let t = trace(w, layout, &rng, sloppy: sloppy) else { continue }
        count(&row, w, m.decode(t, context: context, limit: 4).map { $0.lowercased() }, w)
      }
    }
    return row
  }

  /// Every word of every sentence swiped in turn, with the words before it as context. The sentences are
  /// separate messages, as in a chat: the first word of each has no words before it, only the keyboard's
  /// memory of the language the last message was in.
  static func sentenceSwipeRow(_ name: String, sentences: [String], layout: KeyboardLayout, lexicons: [Lexicon],
                               trials: Int = 5, seed: UInt64 = 13, sloppy: Bool = false, config: Config = Config()) -> Row {
    var m = config.multi(lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) })
    var rng = SeededRandom(state: seed)
    var row = Row(name: name)
    var recent: String?
    for s in sentences {
      m.languagePrior.recentLanguage = recent
      defer { recent = m.languagePrior.likeliest(lexicons, primary: layout.language.rawValue, context: TypingContext(before: s + " ")) }
      let words = s.split(separator: " ").map(String.init)
      for (i, w) in words.enumerated() where w.count >= 2 {
        let context = words.prefix(i).joined(separator: " ") + (i > 0 ? " " : "")
        for _ in 0..<trials {
          guard let t = trace(w, layout, &rng, sloppy: sloppy) else { continue }
          count(&row, w, m.decode(t, context: context, limit: 4).map { $0.lowercased() }, "\(words.prefix(i).last ?? "^") \(w)")
        }
      }
    }
    return row
  }

  /// An engine with `context` already written, as the keyboard's bar would see it.
  static func engine(_ context: String, _ layout: KeyboardLayout, _ lexicons: [Lexicon], _ config: Config) -> TypingEngine {
    let p = FakeProxy()
    p.text = context
    let e = TypingEngine(proxy: p, suggester: config.suggester(lexicons, layout))
    e.resync()
    return e
  }

  /// The bar while the first `n` letters of a word are typed (taps at the key centres): is the word in the
  /// bold middle slot (top-1), or anywhere in the bar (top-4)?
  static func prefixRow(_ name: String, words: [String], n: Int, layout: KeyboardLayout, lexicons: [Lexicon], context: String = "", config: Config = Config()) -> Row {
    var row = Row(name: name)
    for w in words where w.count > n + 1 {
      let e = engine(context, layout, lexicons, config)
      for ch in w.prefix(n) { e.character(String(ch), at: layout.keys.first { $0.label == String(ch) }?.center) }
      barCount(&row, w, e.suggestions().map { $0.word.lowercased() }, String(w.prefix(n)))
    }
    return row
  }

  static func barCount(_ row: inout Row, _ want: String, _ bar: [String], _ label: String) {
    row.total += 1
    if bar.count >= 2 ? bar[1] == want : bar.first == want { row.hit1 += 1 }  // the middle, bold slot
    if bar.contains(want) { row.hit4 += 1 } else if row.misses.count < 30 { row.misses.append("\(label)->\(bar)") }
  }

  /// In each sentence, the bar after the words before a word and a space (`letters` 0), or after its first
  /// letter too (`letters` 1): is the word in it?
  static func sentenceBarRow(_ name: String, sentences: [String], letters: Int, layout: KeyboardLayout, lexicons: [Lexicon], config: Config = Config()) -> Row {
    var row = Row(name: name)
    for s in sentences {
      let words = s.split(separator: " ").map(String.init)
      for (i, w) in words.enumerated() where i > 0 && w.count > letters + 1 {
        let e = engine(words.prefix(i).joined(separator: " ") + " ", layout, lexicons, config)
        for ch in w.prefix(letters) { e.character(String(ch), at: layout.keys.first { $0.label == String(ch) }?.center) }
        barCount(&row, w, e.suggestions().map { $0.word.lowercased() }, "\(words[i - 1]) \(w.prefix(letters))_")
      }
    }
    return row
  }

  /// The bar after a word and a space: does it predict the next one?
  static func nextWordRow(_ name: String, pairs: [(String, String)], layout: KeyboardLayout, lexicons: [Lexicon], context: String = "ok so ", config: Config = Config()) -> Row {
    var row = Row(name: name)
    for (a, b) in pairs {
      let e = engine(context + a + " ", layout, lexicons, config)
      barCount(&row, b, e.suggestions().map { $0.word.lowercased() }, "\(a) _")
    }
    return row
  }

  /// Share of the bar's alternatives after a swipe that are capitalised entries (names, acronyms) or rare words.
  static func junkRow(_ name: String, words: [String], layout: KeyboardLayout, lexicons: [Lexicon], seed: UInt64 = 5, config: Config = Config()) -> Row {
    let m = config.multi(lexicons.map { SwipeDecoder(lexicon: $0, layout: layout) })
    var rng = SeededRandom(state: seed)
    var row = Row(name: name)
    for w in words {
      guard let t = fingerTrace(w, layout: layout, rng: &rng) else { continue }
      for alt in m.decode(t, context: "", limit: 4).dropFirst() {
        row.total += 1
        let f = lexicons.compactMap { $0.frequency(of: alt) }.max() ?? 0
        if alt != alt.lowercased() || f < 100 {
          row.hit1 += 1
          if row.misses.count < 30 { row.misses.append("\(w):\(alt)") }
        }
      }
    }
    return row
  }

  /// Lowercase words ranked 2000 to 2400 by the lexicon's own frequency: rarer than the lists above, so a
  /// prior that is too strong shows up here.
  static func rarer(_ lex: Lexicon) -> [String] { Array(SwipeDecoderTests.commonWords(lex, 2400).dropFirst(2000)) }

  static func pct(_ a: Int, _ n: Int) -> String { n == 0 ? "-" : String(format: "%5.1f%%", 100 * Double(a) / Double(n)) }

  /// The whole table, as the owner's phone runs it: English layout, English and Spanish lexicons.
  static func table(_ en: Lexicon, _ es: Lexicon, config: Config = Config()) -> [Row] {
    let enLayout = KeyboardLayout(width: 402, language: .english), esLayout = KeyboardLayout(width: 402, language: .spanish)
    let both = [en, es]
    let esContext = "Hola, te quería decir que mañana "
    return [
      swipeRow("swipe EN words, EN only", words: english, layout: enLayout, lexicons: [en], config: config),
      swipeRow("swipe EN words, EN+ES", words: english, layout: enLayout, lexicons: both, config: config),
      swipeRow("swipe ES words, ES only (ES layout)", words: spanish, layout: esLayout, lexicons: [es], config: config),
      swipeRow("swipe ES words, EN+ES, ES context", words: spanish, layout: enLayout, lexicons: both, context: esContext, config: config),
      swipeRow("sloppy swipe EN words, EN+ES", words: english, layout: enLayout, lexicons: both, sloppy: true, config: config),
      swipeRow("sloppy swipe ES words, EN+ES, ES context", words: spanish, layout: enLayout, lexicons: both, context: esContext, sloppy: true, config: config),
      swipeRow("swipe rarer EN words (ranks 2000-2400)", words: rarer(en), layout: enLayout, lexicons: both, trials: 1, config: config),
      sentenceSwipeRow("swipe EN sentences in context", sentences: englishSentences, layout: enLayout, lexicons: both, config: config),
      sentenceSwipeRow("sloppy swipe EN sentences in context", sentences: englishSentences, layout: enLayout, lexicons: both, sloppy: true, config: config),
      sentenceSwipeRow("swipe ES sentences in context", sentences: spanishSentences, layout: enLayout, lexicons: both, config: config),
      sentenceSwipeRow("sloppy swipe ES sentences in context", sentences: spanishSentences, layout: enLayout, lexicons: both, sloppy: true, config: config),
      sentenceSwipeRow("sloppy 'hey how is it going' x40", sentences: ["hey how is it going"], layout: enLayout, lexicons: both, trials: 40, sloppy: true, config: config),
      junkRow("junk swipe alternatives (top-1 = junk share)", words: english, layout: enLayout, lexicons: both, config: config),
      prefixRow("bar after 2 letters (EN)", words: english, n: 2, layout: enLayout, lexicons: both, config: config),
      prefixRow("bar after 3 letters (EN)", words: english, n: 3, layout: enLayout, lexicons: both, config: config),
      prefixRow("bar after 2 letters (ES), ES context", words: spanish, n: 2, layout: enLayout, lexicons: both, context: esContext, config: config),
      sentenceBarRow("bar after 1 letter, EN sentences", sentences: englishSentences, letters: 1, layout: enLayout, lexicons: both, config: config),
      sentenceBarRow("bar after 1 letter, ES sentences", sentences: spanishSentences, letters: 1, layout: enLayout, lexicons: both, config: config),
      sentenceBarRow("next word, EN sentences", sentences: englishSentences, letters: 0, layout: enLayout, lexicons: both, config: config),
      sentenceBarRow("next word, ES sentences", sentences: spanishSentences, letters: 0, layout: enLayout, lexicons: both, config: config),
      nextWordRow("next word, EN pairs", pairs: englishPairs, layout: enLayout, lexicons: both, config: config),
      nextWordRow("next word, ES pairs", pairs: spanishPairs, layout: enLayout, lexicons: both, context: "bueno pues ", config: config),
    ]
  }

  /// Milliseconds the engine takes per key, the bar's suggestions included, typing the sentences with taps at
  /// the key centres; and per swipe decode. (p50, p95, max)
  static func latency(_ en: Lexicon, _ es: Lexicon) -> (keys: [Double], swipes: [Double]) {
    let layout = KeyboardLayout(width: 402, language: .english)
    func ms(_ body: () -> Void) -> Double { let t = ContinuousClock.now; body(); return Double((ContinuousClock.now - t).components.attoseconds) / 1e15 }
    func stats(_ v: [Double]) -> [Double] { let s = v.sorted(); return [s[s.count / 2], s[s.count * 95 / 100], s[s.count - 1]] }
    var keys: [Double] = [], swipes: [Double] = []
    let e = engine("", layout, [en, es], Config())
    for s in englishSentences + spanishSentences {
      for ch in s + ". " {
        keys.append(ms {
          if ch == " " { e.space() } else { e.character(String(ch), at: layout.keys.first { $0.label == String(ch) }?.center) }
          _ = e.suggestions()
        })
      }
    }
    let m = MultiSwipeDecoder([en, es].map { SwipeDecoder(lexicon: $0, layout: layout) })
    var rng = SeededRandom(state: 3)
    for w in english.prefix(150) {
      guard let t = fingerTrace(w, layout: layout, rng: &rng) else { continue }
      swipes.append(ms { _ = m.decode(t, context: "I think that ", limit: 4) })
    }
    return (stats(keys), stats(swipes))
  }

  static func printTable(_ rows: [Row], label: String = "eval") {
    print("\(label) | measure | n | top-1 / bold slot | top-4 / in bar")
    for r in rows { print("\(label) | \(r.name) | \(r.total) | \(pct(r.hit1, r.total)) | \(pct(r.hit4, r.total))") }
  }
}

struct QualityEvalTests {
  @Test func swipeAndSuggestionQuality() throws {
    let en = try Fixtures.english.get(), es = try Fixtures.spanish.get()
    let rows = QualityEval.table(en, es)
    QualityEval.printTable(rows)
    for r in rows where !r.misses.isEmpty { print("eval-misses | \(r.name) | \(r.misses.prefix(20))") }
    // floors about two points under the measured values (2026-11-05), so a regression fails the build;
    // the baseline before this evaluation existed is in the commit that added it
    let floors: [String: (top1: Double, top4: Double)] = [
      "swipe EN words, EN+ES": (89, 99), "sloppy swipe EN words, EN+ES": (77, 91),
      "swipe ES words, EN+ES, ES context": (85, 96), "swipe EN sentences in context": (96, 99),
      "sloppy swipe EN sentences in context": (87, 91), "swipe ES sentences in context": (87, 98),
      "sloppy swipe ES sentences in context": (82, 92), "sloppy 'hey how is it going' x40": (84, 88),
      "bar after 3 letters (EN)": (39, 59), "bar after 1 letter, EN sentences": (48, 57),
      "next word, EN pairs": (60, 77), "next word, ES pairs": (50, 70), "next word, EN sentences": (19, 34),
    ]
    for r in rows {
      let top1 = 100 * Double(r.hit1) / Double(max(1, r.total)), top4 = 100 * Double(r.hit4) / Double(max(1, r.total))
      if let f = floors[r.name] {
        #expect(top1 >= f.top1, "\(r.name) top-1 \(top1)")
        #expect(top4 >= f.top4, "\(r.name) top-4 \(top4)")
      }
      if r.name.hasPrefix("junk") { #expect(top1 <= 32, "junk alternatives \(top1)%") }
    }
    let lat = QualityEval.latency(en, es)
    print("eval-latency | key + bar p50/p95/max \(lat.keys.map { String(format: "%.2f", $0) }) ms | swipe decode \(lat.swipes.map { String(format: "%.1f", $0) }) ms")
  }
}
