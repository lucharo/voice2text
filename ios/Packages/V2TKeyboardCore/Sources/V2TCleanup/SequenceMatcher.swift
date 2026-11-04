// A port of CPython's difflib.SequenceMatcher (Lib/difflib.py, 3.13) without `isjunk`: the guard needs
// the exact opcodes Python produces, and difflib's longest-match search breaks ties in a particular way.

public struct DiffMatch: Equatable, Sendable {
  public let a: Int, b: Int, size: Int
}

public struct DiffOpcode: Equatable, Sendable {
  public enum Tag: String, Sendable { case replace, delete, insert, equal }
  public let tag: Tag
  public let i1: Int, i2: Int, j1: Int, j2: Int
}

public struct SequenceMatcher<Element: Hashable> {
  public let a: [Element]
  public let b: [Element]
  /// Elements of `b` treated as junk because they are popular (more than 1% of a `b` of 200 or more).
  public let popular: Set<Element>
  private let b2j: [Element: [Int]]

  /// `autojunk` as in Python, where it defaults to true; it only acts on a `b` of 200 elements or more.
  public init(a: [Element], b: [Element], autojunk: Bool = true) {
    self.a = a
    self.b = b
    var b2j: [Element: [Int]] = [:]
    for (i, elt) in b.enumerated() { b2j[elt, default: []].append(i) }
    var popular = Set<Element>()
    if autojunk && b.count >= 200 {
      let ntest = b.count / 100 + 1
      for (elt, idxs) in b2j where idxs.count > ntest { popular.insert(elt) }
      for elt in popular { b2j[elt] = nil }
    }
    self.b2j = b2j
    self.popular = popular
  }

  /// The longest matching block in a[alo..<ahi] and b[blo..<bhi]; of the longest, the one that starts
  /// earliest in `a`, and of those the one that starts earliest in `b`.
  public func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> DiffMatch {
    var besti = alo, bestj = blo, bestsize = 0
    var j2len: [Int: Int] = [:]
    for i in alo..<max(alo, ahi) {
      var newj2len: [Int: Int] = [:]
      for j in b2j[a[i]] ?? [] {
        if j < blo { continue }
        if j >= bhi { break }
        let k = (j2len[j - 1] ?? 0) + 1
        newj2len[j] = k
        if k > bestsize { (besti, bestj, bestsize) = (i - k + 1, j - k + 1, k) }
      }
      j2len = newj2len
    }
    // Extend with equal non-junk elements on each side (popular elements are not junk here, as in Python;
    // the two junk-extension loops that follow in difflib never run without `isjunk`).
    while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
      (besti, bestj, bestsize) = (besti - 1, bestj - 1, bestsize + 1)
    }
    while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
      bestsize += 1
    }
    return DiffMatch(a: besti, b: bestj, size: bestsize)
  }

  public func matchingBlocks() -> [DiffMatch] {
    let la = a.count, lb = b.count
    var queue = [(0, la, 0, lb)]
    var blocks: [DiffMatch] = []
    while let (alo, ahi, blo, bhi) = queue.popLast() {
      let x = findLongestMatch(alo, ahi, blo, bhi)
      let (i, j, k) = (x.a, x.b, x.size)
      if k > 0 {
        blocks.append(x)
        if alo < i && blo < j { queue.append((alo, i, blo, j)) }
        if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
      }
    }
    blocks.sort { ($0.a, $0.b, $0.size) < ($1.a, $1.b, $1.size) }
    var (i1, j1, k1) = (0, 0, 0)
    var nonAdjacent: [DiffMatch] = []
    for m in blocks {
      if i1 + k1 == m.a && j1 + k1 == m.b {
        k1 += m.size
      } else {
        if k1 > 0 { nonAdjacent.append(DiffMatch(a: i1, b: j1, size: k1)) }
        (i1, j1, k1) = (m.a, m.b, m.size)
      }
    }
    if k1 > 0 { nonAdjacent.append(DiffMatch(a: i1, b: j1, size: k1)) }
    nonAdjacent.append(DiffMatch(a: la, b: lb, size: 0))
    return nonAdjacent
  }

  public func opcodes() -> [DiffOpcode] {
    var i = 0, j = 0
    var answer: [DiffOpcode] = []
    for m in matchingBlocks() {
      let tag: DiffOpcode.Tag? =
        i < m.a && j < m.b ? .replace : i < m.a ? .delete : j < m.b ? .insert : nil
      if let tag { answer.append(DiffOpcode(tag: tag, i1: i, i2: m.a, j1: j, j2: m.b)) }
      (i, j) = (m.a + m.size, m.b + m.size)
      if m.size > 0 { answer.append(DiffOpcode(tag: .equal, i1: m.a, i2: i, j1: m.b, j2: j)) }
    }
    return answer
  }

  public func ratio() -> Double {
    let matches = matchingBlocks().reduce(0) { $0 + $1.size }
    let length = a.count + b.count
    return length > 0 ? 2.0 * Double(matches) / Double(length) : 1.0
  }
}
