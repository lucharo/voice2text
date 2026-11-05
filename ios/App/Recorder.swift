@preconcurrency import AVFoundation

/// Microphone capture as 16 kHz mono floats. The engine keeps running between dictations while the session
/// is warm, so a dictation the keyboard starts from the background begins instantly: iOS lets a background
/// app keep an audio session it started in the foreground, never start a new one.
protocol AudioSource: AnyObject, Sendable {
  var running: Bool { get }
  func warmUp() throws
  func coolDown()
  func begin()
  func end() -> [Float]
  /// Root-mean-square of the latest audio while recording, 0 otherwise.
  var level: Float { get }
}

final class Recorder: AudioSource, @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var samples: [Float] = []
  private var capturing = false
  private var converter: AVAudioConverter?
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  private(set) var running = false
  private var lastLevel: Float = 0

  var level: Float { lock.lock(); defer { lock.unlock() }; return capturing ? lastLevel : 0 }

  /// Activates the audio session and starts the input tap (call from the foreground).
  ///
  /// Set up so other apps' music plays as it would without v2t, since the input runs between dictations too:
  /// mode default rather than measurement (which "disables some dynamics processing on input and output
  /// resulting in a lower output playback level", AVAudioSessionTypes.h), and Bluetooth headphones as A2DP
  /// output only (no HFP, which turns them into a mono call headset), so the iPhone's own mic records.
  func warmUp() throws {
    guard !running else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: Self.options)
    try session.setActive(true)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    converter = AVAudioConverter(from: format, to: target)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in self?.append(buffer) }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      // roll back, so a retry does not install a second tap on the same bus (which crashes)
      release()
      throw error
    }
    running = true
  }

  /// Stops the tap and releases the microphone (the orange dot goes away). A dictation in progress is dropped.
  func coolDown() {
    guard running else { return }
    release()
    running = false
  }

  static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]

  private func release() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    lock.lock(); capturing = false; samples = []; lock.unlock()
  }

  func begin() {
    lock.lock(); samples = []; capturing = true; lock.unlock()
  }

  func end() -> [Float] {
    lock.lock(); defer { lock.unlock() }
    capturing = false
    let out = samples
    samples = []
    return out
  }

  private func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock(); let on = capturing; lock.unlock()
    guard on, let converter else { return }
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed { status.pointee = .noDataNow; return nil }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let ch = out.floatChannelData else { return }
    let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    let rms = chunk.isEmpty ? 0 : (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
    lock.lock(); if capturing { samples += chunk; lastLevel = rms }; lock.unlock()
  }
}

/// UI tests only (V2T_FIXTURE_AUDIO): "records" a synthetic clip instead of the microphone, so a Simulator
/// run never captures the room around the Mac. The clip is 16 kHz mono 32-bit float WAV made by setup.sh
/// with macOS `say`.
final class FixtureAudio: AudioSource, @unchecked Sendable {
  private let samples: [Float]
  private(set) var running = false
  init?(path: String) {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
    samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
  }
  private var began: Date?
  func warmUp() throws { running = true }
  func coolDown() { running = false }
  func begin() { began = Date() }
  func end() -> [Float] { began = nil; return samples }
  /// The clip's level at the time since begin(), looping, so the keyboard's waveform moves in UI tests.
  var level: Float {
    guard let began, !samples.isEmpty else { return 0 }
    let at = Int(Date().timeIntervalSince(began) * 16_000) % samples.count
    let window = samples[at..<min(samples.count, at + 800)]
    return (window.reduce(0) { $0 + $1 * $1 } / Float(max(1, window.count))).squareRoot()
  }
}
