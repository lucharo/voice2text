// Swift port of Bark 3.0's bark_coreml.py: numpy frontend, Core ML encoder (w8 / w15 windows), TDT greedy decoder.
import Accelerate
import CoreML
import Foundation

final class BarkTranscriber {
  static let SR = 16000, HOP = 160, NFFT = 512, WIN = 400, NMEL = 128, NBIN = 257
  let windows: [Int]
  var encoders: [Int: MLModel] = [:]
  // decoder weights
  let blob: [Float]
  let idx: [String: (Int, [Int])]
  let V: Int, blank: Int, durations: [Int], maxSym: Int, pieces: [String], special: Set<Int>
  let H = 640
  // frontend tables
  var window = [Float](repeating: 0, count: NFFT)
  var cosM = [Float](), sinM = [Float]()  // [NFFT, NBIN]
  let pad = 4000  // 0.25 s

  init(folder: URL, units: MLComputeUnits, encoder: URL? = nil, windows: [Int]? = nil, log: (String) -> Void = { _ in }) throws {
    self.windows = windows ?? [8, 15]
    let data = try Data(contentsOf: folder.appendingPathComponent("decoder.f32"))
    blob = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let j = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("decoder.json"))) as! [String: [String: Any]]
    var m: [String: (Int, [Int])] = [:]
    for (k, v) in j { m[k] = (v["offset"] as! Int, v["shape"] as! [Int]) }
    idx = m
    let voc = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("vocab.json"))) as! [String: Any]
    V = voc["vocab_size"] as! Int; blank = voc["blank_id"] as! Int; durations = voc["durations"] as! [Int]
    maxSym = voc["max_symbols_per_step"] as! Int; pieces = voc["pieces"] as! [String]
    special = Set(voc["special_ids"] as! [Int])
    // symmetric hann(400) centred in 512
    let off = (Self.NFFT - Self.WIN) / 2
    for i in 0..<Self.WIN { window[off + i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(Self.WIN - 1))) }
    cosM = [Float](repeating: 0, count: Self.NFFT * Self.NBIN); sinM = cosM
    for n in 0..<Self.NFFT { for k in 0..<Self.NBIN {
      let a = 2 * Double.pi * Double(n * k) / Double(Self.NFFT)
      cosM[n * Self.NBIN + k] = Float(cos(a)); sinM[n * Self.NBIN + k] = Float(sin(a))
    } }
    log("tables")
    for w in self.windows {
      log("load w\(w)")
      let cfg = MLModelConfiguration(); cfg.computeUnits = units; cfg.functionName = "w\(w)"
      encoders[w] = try MLModel(contentsOf: encoder ?? folder.appendingPathComponent("BarkEncoder.mlmodelc"), configuration: cfg)
      log("loaded w\(w)")
    }
  }

  func w(_ k: String) -> UnsafeBufferPointer<Float> {
    let (o, s) = idx[k]!; let n = s.reduce(1, *)
    return blob.withUnsafeBufferPointer { UnsafeBufferPointer(rebasing: $0[o..<(o + n)]) }
  }

  // y = A x + b ; A is [rows, cols] row-major
  func gemv(_ a: String, _ x: [Float], rows: Int, cols: Int, bias: [Float]? = nil) -> [Float] {
    var y = bias ?? [Float](repeating: 0, count: rows)
    let A = w(a)
    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(cols), 1, A.baseAddress, Int32(cols), x, 1, bias == nil ? 0 : 1, &y, 1)
    return y
  }

  func frontend(_ xin: [Float]) -> ([Float], Int, Int) {  // feats [n, 128], n, valid
    let L = xin.count
    var x = xin
    for i in stride(from: L - 1, to: 0, by: -1) { x[i] = xin[i] - 0.97 * xin[i - 1] }
    let half = Self.NFFT / 2
    let xp = [Float](repeating: 0, count: half) + x + [Float](repeating: 0, count: half)
    let n = 1 + (xp.count - Self.NFFT) / Self.HOP
    var frames = [Float](repeating: 0, count: n * Self.NFFT)
    for f in 0..<n { for i in 0..<Self.NFFT { frames[f * Self.NFFT + i] = xp[f * Self.HOP + i] * window[i] } }
    var re = [Float](repeating: 0, count: n * Self.NBIN), im = re
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(Self.NBIN), Int32(Self.NFFT), 1, frames, Int32(Self.NFFT), cosM, Int32(Self.NBIN), 0, &re, Int32(Self.NBIN))
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(Self.NBIN), Int32(Self.NFFT), 1, frames, Int32(Self.NFFT), sinM, Int32(Self.NBIN), 0, &im, Int32(Self.NBIN))
    var power = [Float](repeating: 0, count: n * Self.NBIN)
    for i in 0..<power.count { power[i] = re[i] * re[i] + im[i] * im[i] }
    // feats = log(power @ mel.T + 2^-24); mel is [128, 257]
    var feats = [Float](repeating: 0, count: n * Self.NMEL)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(Self.NMEL), Int32(Self.NBIN), 1, power, Int32(Self.NBIN), w("mel_filters").baseAddress, Int32(Self.NBIN), 0, &feats, Int32(Self.NMEL))
    for i in 0..<feats.count { feats[i] = log(feats[i] + powf(2, -24)) }
    let valid = L / Self.HOP
    for c in 0..<Self.NMEL {
      var mean: Double = 0
      for t in 0..<valid { mean += Double(feats[t * Self.NMEL + c]) }
      mean /= Double(max(valid, 1))
      var ss: Double = 0
      for t in 0..<valid { let d = Double(feats[t * Self.NMEL + c]) - mean; ss += d * d }
      let std = sqrt(ss / Double(max(1, valid - 1)))
      for t in 0..<n { feats[t * Self.NMEL + c] = t < valid ? Float((Double(feats[t * Self.NMEL + c]) - mean) / (std + 1e-5)) : 0 }
    }
    return (feats, n, valid)
  }

  func encLen(_ n0: Int) -> Int { var n = n0; for _ in 0..<3 { n = (n - 1) / 2 + 1 }; return n }

  func step(_ tok: Int, _ state: inout [([Float], [Float])]) -> [Float] {
    let emb = w("decoder.embedding.weight")
    var x = Array(emb[(tok * H)..<((tok + 1) * H)])
    for l in 0..<2 {
      let bias = zip(Array(w("decoder.lstm.bias_ih_l\(l)")), Array(w("decoder.lstm.bias_hh_l\(l)"))).map(+)
      var g = gemv("decoder.lstm.weight_ih_l\(l)", x, rows: 4 * H, cols: H, bias: bias)
      let gh = gemv("decoder.lstm.weight_hh_l\(l)", state[l].0, rows: 4 * H, cols: H)
      for i in 0..<g.count { g[i] += gh[i] }
      var h = [Float](repeating: 0, count: H), c = state[l].1
      for i in 0..<H {
        let ig = 1 / (1 + exp(-g[i])), fg = 1 / (1 + exp(-g[H + i])), gg = tanh(g[2 * H + i]), og = 1 / (1 + exp(-g[3 * H + i]))
        c[i] = fg * c[i] + ig * gg; h[i] = og * tanh(c[i])
      }
      state[l] = (h, c); x = h
    }
    return gemv("decoder.decoder_projector.weight", x, rows: H, cols: H, bias: Array(w("decoder.decoder_projector.bias")))
  }

  func decode(_ enc: [Float], T: Int) -> [Int] {
    var state = [([Float](repeating: 0, count: H), [Float](repeating: 0, count: H)), ([Float](repeating: 0, count: H), [Float](repeating: 0, count: H))]
    var dec = step(blank, &state)
    let nOut = V + durations.count
    let headB = Array(w("joint.head.bias"))
    var t = 0, out: [Int] = [], sym = 0
    while t < T {
      var z = [Float](repeating: 0, count: H)
      for i in 0..<H { z[i] = max(enc[t * H + i] + dec[i], 0) }
      let logits = gemv("joint.head.weight", z, rows: nOut, cols: H, bias: headB)
      var tok = 0, best = -Float.infinity
      for i in 0..<V where logits[i] > best { best = logits[i]; tok = i }
      var di = 0; best = -Float.infinity
      for i in 0..<durations.count where logits[V + i] > best { best = logits[V + i]; di = i }
      var d = durations[di]
      if tok == blank { t += max(d, 1); sym = 0 } else {
        out.append(tok); dec = step(tok, &state); sym += 1
        if d == 0 && sym >= maxSym { d = 1 }
        if d > 0 { sym = 0 }
        t += d
      }
    }
    return out
  }

  func detok(_ ids: [Int]) -> String {
    ids.filter { !special.contains($0) && $0 < pieces.count }.map { pieces[$0] }.joined()
      .replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
  }

  func piece(_ x0: [Float]) throws -> [Int] {
    let x = [Float](repeating: 0, count: pad) + x0
    let (feats, n, valid) = frontend(x)
    let wsec = windows.first { x.count <= $0 * Self.SR }!
    let T = wsec * 100 + 1
    let f = try MLMultiArray(shape: [1, NSNumber(value: T), 128], dataType: .float16)
    let m = try MLMultiArray(shape: [1, NSNumber(value: T)], dataType: .int32)
    let fp = f.dataPointer.bindMemory(to: Float16.self, capacity: T * 128)
    let mp = m.dataPointer.bindMemory(to: Int32.self, capacity: T)
    for i in 0..<(T * 128) { fp[i] = 0 }
    for t in 0..<min(n, T) { for c in 0..<128 { fp[t * 128 + c] = Float16(feats[t * Self.NMEL + c]) } }
    for t in 0..<T { mp[t] = t < valid ? 1 : 0 }
    let out = try encoders[wsec]!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": f, "mask": m]))
    let e = out.featureValue(for: "encoded")!.multiArrayValue!
    let Tp = encLen(valid)
    var enc = [Float](repeating: 0, count: Tp * H)
    let s1 = e.strides[1].intValue, s2 = e.strides[2].intValue
    if e.dataType == .float16 {
      let p = e.dataPointer.bindMemory(to: Float16.self, capacity: e.count)
      for t in 0..<Tp { for i in 0..<H { enc[t * H + i] = Float(p[t * s1 + i * s2]) } }
    } else {
      let p = e.dataPointer.bindMemory(to: Float.self, capacity: e.count)
      for t in 0..<Tp { for i in 0..<H { enc[t * H + i] = p[t * s1 + i * s2] } }
    }
    return decode(enc, T: Tp)
  }

  func segments(_ x: [Float], maxS: Double = 14.75, minS: Double = 5.0) -> [[Float]] {
    if x.count <= Int(maxS * Double(Self.SR)) { return [x] }
    let fr = Self.SR / 100, nf = x.count / fr
    var e = [Float](repeating: 0, count: nf)
    for i in 0..<nf { var s: Float = 0; for j in 0..<fr { s += x[i * fr + j] * x[i * fr + j] }; e[i] = s / Float(fr) }
    // np.convolve(e, ones(20)/20, mode="same")
    var sm = [Float](repeating: 0, count: nf)
    for i in 0..<nf { var s: Float = 0; for k in 0..<20 { let j = i + 9 - k; if j >= 0 && j < nf { s += e[j] } }; sm[i] = s / 20 }
    var out: [[Float]] = [], start = 0
    while Double(x.count - start) > maxS * Double(Self.SR) {
      let lo = (start + Int(minS * Double(Self.SR))) / fr, hi = (start + Int(maxS * Double(Self.SR))) / fr
      var best = lo
      for i in lo..<hi where sm[i] < sm[best] { best = i }
      let cut = best * fr + fr / 2
      out.append(Array(x[start..<cut])); start = cut
    }
    out.append(Array(x[start...]))
    return out
  }

  func transcribe(_ wave: [Float]) throws -> String {
    try segments(wave).map { detok(try piece($0)) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
  }
}
