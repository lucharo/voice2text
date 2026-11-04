import Foundation

/// A read-only word list in the `.v2tlex` format written by ios/tools/build_lexicons.py, memory-mapped so its
/// pages are clean and file-backed rather than counted against the keyboard extension's memory limit.
///
/// Entries are sorted by their folded key (lowercase a-z only: accents and ñ fold to the base letter,
/// apostrophes and hyphens drop), so every word a typist could mean by a run of letter keys sits in one
/// contiguous range, and a prefix is a binary search.
public final class Lexicon: @unchecked Sendable {
  public let language: String
  public let count: Int
  private let data: Data
  private let keyOffsets: Int, wordOffsets: Int, freqs: Int, keyBlob: Int, wordBlob: Int

  public struct FormatError: Error, CustomStringConvertible {
    public let description: String
  }

  public convenience init(contentsOf url: URL, language: String) throws {
    try self.init(data: Data(contentsOf: url, options: .alwaysMapped), language: language)
  }

  public init(data: Data, language: String) throws {
    guard data.count >= 20, data.prefix(4) == Data("V2TL".utf8) else { throw FormatError(description: "not a v2tlex file") }
    func u32(_ at: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian }) }
    guard u32(4) == 1 else { throw FormatError(description: "unsupported v2tlex version \(u32(4))") }
    let n = u32(8), keyLen = u32(12), wordLen = u32(16)
    keyOffsets = 20
    wordOffsets = keyOffsets + 4 * (n + 1)
    freqs = wordOffsets + 4 * (n + 1)
    keyBlob = freqs + n
    wordBlob = keyBlob + keyLen
    guard wordBlob + wordLen == data.count else { throw FormatError(description: "v2tlex size mismatch") }
    self.data = data
    self.count = n
    self.language = language
  }

  @inline(__always) private func offset(_ table: Int, _ i: Int) -> Int {
    Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: table + 4 * i, as: UInt32.self).littleEndian })
  }

  /// The folded key of entry `i` as raw bytes (a-z).
  @inline(__always) public func withKey<R>(_ i: Int, _ body: (UnsafeRawBufferPointer) -> R) -> R {
    let a = offset(keyOffsets, i), b = offset(keyOffsets, i + 1)
    return data.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[(keyBlob + a)..<(keyBlob + b)])) }
  }

  public func key(_ i: Int) -> String { withKey(i) { String(decoding: $0, as: UTF8.self) } }

  public func word(_ i: Int) -> String {
    let a = offset(wordOffsets, i), b = offset(wordOffsets, i + 1)
    return data.withUnsafeBytes { String(decoding: UnsafeRawBufferPointer(rebasing: $0[(wordBlob + a)..<(wordBlob + b)]), as: UTF8.self) }
  }

  /// 0-255; 0 means a valid word that is never suggested (offensive or very rare).
  public func frequency(_ i: Int) -> Int { Int(data[data.startIndex + freqs + i]) }

  public func keyLength(_ i: Int) -> Int { offset(keyOffsets, i + 1) - offset(keyOffsets, i) }

  /// Entries whose key starts with `prefix` (folded bytes), within `range`.
  public func prefixRange(_ prefix: [UInt8], in range: Range<Int>? = nil) -> Range<Int> {
    let r = range ?? 0..<count
    let lo = lowerBound(prefix, in: r, inclusiveOfPrefix: false)
    let hi = lowerBound(prefix, in: lo..<r.upperBound, inclusiveOfPrefix: true)
    return lo..<hi
  }

  /// Entries whose key equals `key` exactly (several words can share one key: "como", "cómo").
  public func exactRange(_ key: [UInt8]) -> Range<Int> {
    let p = prefixRange(key)
    var end = p.lowerBound
    while end < p.upperBound, keyLength(end) == key.count { end += 1 }
    return p.lowerBound..<end
  }

  /// First index in `range` whose key compares >= `prefix` (or, when `inclusiveOfPrefix`, whose key does not
  /// start with `prefix` and compares greater).
  private func lowerBound(_ prefix: [UInt8], in range: Range<Int>, inclusiveOfPrefix: Bool) -> Int {
    var lo = range.lowerBound, hi = range.upperBound
    while lo < hi {
      let mid = (lo + hi) / 2
      let c = withKey(mid) { compare($0, prefix) }
      if c < 0 || (inclusiveOfPrefix && c == 0) { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// Compares a key's first `prefix.count` bytes with `prefix` (shorter keys that match sort before).
  @inline(__always) private func compare(_ key: UnsafeRawBufferPointer, _ prefix: [UInt8]) -> Int {
    let n = min(key.count, prefix.count)
    for j in 0..<n where key[j] != prefix[j] { return key[j] < prefix[j] ? -1 : 1 }
    return key.count < prefix.count ? -1 : 0
  }

  /// The typist's folded form of any text.
  public static func fold(_ s: String) -> [UInt8] {
    s.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars.compactMap { u in
      (0x61...0x7A).contains(u.value) ? UInt8(u.value) : nil
    }
  }
}

extension Lexicon {
  /// Builds a lexicon in memory, for the user's own words (learned words, the v2t dictionary). Same format
  /// and ordering as ios/tools/build_lexicons.py.
  public static func build(_ entries: [(word: String, frequency: Int)], language: String) throws -> Lexicon {
    var best: [String: (Int, [UInt8])] = [:]
    for (w, f) in entries {
      let k = fold(w)
      guard !k.isEmpty else { continue }
      if let old = best[w], old.0 >= f { continue }
      best[w] = (max(0, min(255, f)), k)
    }
    let rows = best.map { (key: $0.value.1, freq: $0.value.0, word: $0.key) }.sorted {
      $0.key != $1.key ? $0.key.lexicographicallyPrecedes($1.key) : ($0.freq != $1.freq ? $0.freq > $1.freq : Array($0.word.utf8).lexicographicallyPrecedes(Array($1.word.utf8)))
    }
    var keys = [UInt8](), words = [UInt8](), freqs = [UInt8]()
    var ko: [UInt32] = [0], wo: [UInt32] = [0]
    for r in rows {
      keys += r.key
      words += Array(r.word.utf8)
      ko.append(UInt32(keys.count))
      wo.append(UInt32(words.count))
      freqs.append(UInt8(r.freq))
    }
    var d = Data("V2TL".utf8)
    func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    for v in [1, UInt32(rows.count), UInt32(keys.count), UInt32(words.count)] { put(v) }
    ko.forEach(put)
    wo.forEach(put)
    d.append(contentsOf: freqs)
    d.append(contentsOf: keys)
    d.append(contentsOf: words)
    return try Lexicon(data: d, language: language)
  }
}
