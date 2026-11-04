// Chunking, the length guard and the casual-mode word guard, ported from v2t/backends.py (`chunk_text`,
// `within_length_guard`, `sounds_alike`, `keep_spoken_words`). golden.json, written by
// ios/tools/cleanup_golden.py from the Python, pins every output; see backends.py for the measurements
// behind each constant.

/// Long dictations go through the model in sentence-aligned chunks of about this many words.
public let chunkWords = 120

/// A chunk whose cleaned word count falls outside (low, high) of the raw chunk's is replaced by the raw.
public func lengthGuard(_ mode: CleanupMode) -> (low: Double, high: Double) {
  switch mode {
  case .strict: (0.6, 1.3)
  case .casual: (0.75, 1.3)
  }
}

private let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?", "…"]

/// `re.split(r"(?<=[.!?…])\s+", text)`.
private func splitSentences(_ text: PyStr) -> [PyStr] {
  var parts: [PyStr] = [], start = 0, i = 0
  while i < text.count {
    if Py.isSpace(text[i]) && i > 0 && sentenceEnds.contains(text[i - 1]) {
      var end = i
      while end < text.count && Py.isSpace(text[end]) { end += 1 }
      parts.append(Array(text[start..<i]))
      (start, i) = (end, end)
    } else {
      i += 1
    }
  }
  parts.append(Array(text[start...]))
  return parts
}

/// Split on sentence ends into chunks of at most ~maxWords words; a single sentence longer than that is
/// split on word boundaries instead.
public func chunkText(_ text: String, maxWords: Int = chunkWords) -> [String] {
  var chunks: [String] = [], current: [String] = []
  var count = 0
  for sentence in splitSentences(Py.strip(text.py)) {
    let words = Py.split(sentence).map { String(py: $0) }
    if words.isEmpty { continue }
    if words.count > maxWords {
      if !current.isEmpty {
        chunks.append(current.joined(separator: " "))
        (current, count) = ([], 0)
      }
      for start in stride(from: 0, to: words.count, by: maxWords) {
        chunks.append(words[start..<min(start + maxWords, words.count)].joined(separator: " "))
      }
      continue
    }
    if count + words.count > maxWords && !current.isEmpty {
      chunks.append(current.joined(separator: " "))
      (current, count) = ([], 0)
    }
    current.append(String(py: Py.strip(sentence)))
    count += words.count
  }
  if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
  return chunks
}

/// Whether the cleaned text kept a plausible share of the raw words for `mode`.
public func withinLengthGuard(raw: String, clean: String, mode: CleanupMode) -> Bool {
  let (low, high) = lengthGuard(mode)
  let rawWords = Py.split(raw.py).count
  let cleanWords = Py.split(clean.py).count
  if rawWords == 0 { return cleanWords == 0 }
  let ratio = Double(cleanWords) / Double(rawWords)
  return low <= ratio && ratio <= high
}

/// Fillers casual cleanup may drop.
let casualDroppable: Set<PyStr> = Set(["um", "uh", "erm", "er", "uhm", "hmm", "mm", "ah"].map(\.py))

/// Words a number written in digits can stand for ("twenty five percent" -> "25%").
let numberWords: Set<PyStr> = Set(
  ("zero oh one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    + "fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty "
    + "ninety hundred thousand million billion trillion point and a percent per cent first second "
    + "third fourth fifth sixth seventh eighth ninth tenth half quarter minus dollars dollar pounds "
    + "pound euros euro cents pence o'clock am pm number").split(separator: " ").map { String($0).py })

private let trailingMarks: Set<Unicode.Scalar> = [".", ",", ";", ":", "!", "?", "…"]
private let endMarks: Set<Unicode.Scalar> = [".", "!", "?", "…"]
private let softLetters: Set<Unicode.Scalar> = ["a", "e", "i", "o", "u", "h", "w", "y", "'"]

/// `_bare`: the token without anything but word characters and apostrophes, lowercased.
func bare(_ token: PyStr) -> PyStr { Py.lower(token.filter { Py.isWord($0) || $0 == "'" }) }

func bare(_ token: String) -> PyStr { bare(token.py) }

func soundsAlike(_ spoken: PyStr, _ written: PyStr) -> Bool {
  func skeleton(_ word: PyStr) -> PyStr {
    let word = bare(word)
    return Array(word.prefix(1)) + word.dropFirst().filter { !softLetters.contains($0) }
  }
  return SequenceMatcher(a: skeleton(spoken), b: skeleton(written)).ratio() >= 0.5
}

/// Whether a dictionary word could be what a misheard word meant ("clock", "clot" -> "Claude"): their first
/// letters and consonants ("clck", "cld") match at least half way by difflib's ratio.
public func soundsAlike(_ spoken: String, _ written: String) -> Bool { soundsAlike(spoken.py, written.py) }

public struct SpokenWordCounts: Equatable, Sendable {
  /// Words the cleanup dropped, put back.
  public var restored = 0
  /// Words the cleanup changed, put back.
  public var reverted = 0
  /// Words the cleanup added, taken out.
  public var removed = 0
  public init(restored: Int = 0, reverted: Int = 0, removed: Int = 0) {
    (self.restored, self.reverted, self.removed) = (restored, reverted, removed)
  }
}

/// `clean` held to the words of `raw`. The two are aligned on bare lowercase words, so punctuation and
/// casing stay as cleaned. A dropped stretch comes back unless it is a filler or an immediate repeat; a
/// changed or added stretch is kept only when each of its words holds a digit or `#`, was said in that
/// stretch or is a dictionary word standing in for a similar-sounding word said there, in order, one for
/// one. Words put back go before the punctuation that ended the cleaned word ahead of them.
public func keepSpokenWords(
  raw: String, clean: String, vocabulary: [String] = []
) -> (text: String, counts: SpokenWordCounts) {
  let allowed = Set(vocabulary.flatMap { Py.split($0.py) }.map { bare($0) })
  let rawTokens = Py.split(raw.py), cleanTokens = Py.split(clean.py)
  let rawBare = rawTokens.map { bare($0) }
  var out: [PyStr] = []
  var counts = SpokenWordCounts()

  func number(_ token: PyStr) -> Bool { token.contains { Py.isDigit($0) } || token.contains("#") }

  /// A word the cleanup may write: a number in digits or a dictionary word.
  func license(_ token: PyStr) -> Bool { number(token) || allowed.contains(bare(token)) }

  func trailing(_ token: PyStr) -> PyStr? { Py.trailingRun(token, of: trailingMarks)?.run }

  /// Each written word licensed or said in this stretch, at least one licensed, and each word said there
  /// written or a number word unless a dictionary word replaced it.
  func licensed(_ tokens: ArraySlice<PyStr>, _ i1: Int, _ i2: Int) -> Bool {
    let written = Set(tokens.map { bare($0) })
    let spoken = Set(rawBare[i1..<i2])
    let digits = tokens.contains(where: number)
    let unwritten = (i1..<i2).map { rawBare[$0] }.enumerated().compactMap { offset, w -> PyStr? in
      let i = i1 + offset
      let accounted =
        written.contains(w)
        || (digits && numberWords.contains(w))
        || casualDroppable.contains(w)
        || (i > 0 && rawBare[i - 1] == w)
        || (i == i2 - 1 && i + 1 < rawBare.count && rawBare[i + 1] == w)
      return accounted ? nil : w
    }
    let swapped = tokens.compactMap { t -> (word: PyStr, hasDigit: Bool)? in
      let b = bare(t)
      return allowed.contains(b) && !spoken.contains(b) ? (b, number(t)) : nil
    }

    func pairsUp() -> Bool {
      var said = unwritten.makeIterator()
      var pending = said.next()
      for (word, hasDigit) in swapped {
        if let said_ = pending, soundsAlike(said_, word) {
          pending = said.next()
        } else if !hasDigit {
          return false
        }
      }
      return pending == nil
    }

    return tokens.allSatisfy { license($0) || spoken.contains(bare($0)) }
      && tokens.contains(where: license)
      && pairsUp()
  }

  /// `word` capitalised when the cleaned word it replaces starts a sentence.
  func cased(_ word: PyStr, like: PyStr) -> PyStr {
    guard let l = like.first, Py.isUpper(l), let w = word.first, Py.isLower(w) else { return word }
    return Py.upper(w) + word.dropFirst()
  }

  /// Append `words`, ending with `trailing` unless they carry their own.
  func putBack(_ words: [PyStr], _ trailingMark: PyStr) {
    var words = words
    if !trailingMark.isEmpty && trailing(words[words.count - 1]) == nil {
      words[words.count - 1] += trailingMark
    }
    out.append(contentsOf: words)
  }

  let matcher = SequenceMatcher(a: rawBare, b: cleanTokens.map { bare($0) }, autojunk: false)
  for op in matcher.opcodes() {
    var (i1, i2, j1, j2) = (op.i1, op.i2, op.j1, op.j2)
    switch op.tag {
    case .equal:
      out.append(contentsOf: cleanTokens[j1..<j2])

    case .insert:  // nothing was said there, so nothing is written
      let added = cleanTokens[j1..<j2].filter { !bare($0).isEmpty }
      counts.removed += added.count
      if added.isEmpty {
        out.append(contentsOf: cleanTokens[j1..<j2])
      } else if j2 == cleanTokens.count, let last = out.last, Py.trailingRun(last, of: endMarks) == nil,
        let mark = Py.trailingRun(cleanTokens[j2 - 1], of: endMarks)
      {
        out[out.count - 1] += mark.run  // the text still ends where the cleanup ended it
      }

    case .replace:
      // peel word-for-word edits off both ends ("says twenty five" -> "said 25": "says" comes back, "25"
      // stays), then keep or revert what is left
      var head: [PyStr] = [], tail: [PyStr] = []
      var pending: PyStr = []  // punctuation of a peeled word, for the end of what comes back
      while i1 < i2 && j1 < j2 && !number(rawTokens[i1]) && !license(cleanTokens[j1]) {
        let mark = trailing(cleanTokens[j1])
        head.append(cased(rawTokens[i1], like: cleanTokens[j1]))
        pending = mark != nil && trailing(rawTokens[i1]) == nil ? mark! : []
        (i1, j1) = (i1 + 1, j1 + 1)
      }
      while i1 < i2 && j1 < j2 && !number(rawTokens[i2 - 1]) && !license(cleanTokens[j2 - 1]) {
        let mark = trailing(cleanTokens[j2 - 1])
        let word = rawTokens[i2 - 1]
        tail.insert(word + (mark != nil && trailing(word) == nil ? mark! : []), at: 0)
        (i2, j2) = (i2 - 1, j2 - 1)
      }
      if !pending.isEmpty && j1 == j2 && i1 < i2 && tail.isEmpty {
        // "it's." -> "it is.": the full stop goes after the last word put back
        if trailing(rawTokens[i2 - 1]) != nil { pending = [] }
      } else if !pending.isEmpty {  // "She said." -> "She says."; "left. Claude" -> "leaves. Claude"
        head[head.count - 1] += pending
        pending = []
      }
      out.append(contentsOf: head)
      if i1 < i2 || j1 < j2 {
        if j1 < j2 && licensed(cleanTokens[j1..<j2], i1, i2) {
          out.append(contentsOf: cleanTokens[j1..<j2])
        } else if i1 < i2 {
          let mark = j1 < j2 && tail.isEmpty ? trailing(cleanTokens[j2 - 1]) : nil
          var words = Array(rawTokens[i1..<i2])
          if j1 < j2 && head.isEmpty { words[0] = cased(words[0], like: cleanTokens[j1]) }
          putBack(words, mark ?? pending)
          counts.reverted += i2 - i1
        }
      }
      out.append(contentsOf: tail)
      counts.reverted += head.count + tail.count

    case .delete:
      var kept: [PyStr] = []
      for i in i1..<i2 {
        let word = rawBare[i]
        // a repeat of a word kept just outside this stretch, or of one already handled inside it: of
        // "can can" dropped whole, one "can" comes back
        let isRepeat =
          (i > i1 && rawBare[i - 1] == word)
          || (i == i1 && i > 0 && rawBare[i - 1] == word)
          || (i == i2 - 1 && i + 1 < rawBare.count && rawBare[i + 1] == word)
        if !word.isEmpty && !casualDroppable.contains(word) && !isRepeat { kept.append(rawTokens[i]) }
      }
      if !kept.isEmpty {
        // "Send it to me." + "please" reads "Send it to me please.": the punctuation that ended the
        // cleaned text moves past the words put back at its end (a comma before "and" stays put)
        var trailingMark: PyStr = []
        if j1 == cleanTokens.count, let last = out.last, let mark = Py.trailingRun(last, of: endMarks) {
          out[out.count - 1] = Array(last[..<mark.start])
          trailingMark = mark.run
        }
        putBack(kept, trailingMark)
        counts.restored += kept.count
      }
    }
  }
  return (out.map { String(py: $0) }.joined(separator: " "), counts)
}
