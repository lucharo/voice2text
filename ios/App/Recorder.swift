@preconcurrency import AVFoundation

/// Microphone capture as 16 kHz mono floats. The engine keeps running between dictations while the session
/// is warm, so a dictation the keyboard starts from the background begins instantly: iOS lets a background
/// app keep an audio session it started in the foreground, never start a new one.
final class Recorder: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var samples: [Float] = []
  private var capturing = false
  private var converter: AVAudioConverter?
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  private(set) var running = false

  /// Activates the audio session and starts the input tap (call from the foreground).
  func warmUp() throws {
    guard !running else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
    try session.setActive(true)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    converter = AVAudioConverter(from: format, to: target)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in self?.append(buffer) }
    engine.prepare()
    try engine.start()
    running = true
  }

  /// Stops the tap and releases the microphone (the orange dot goes away).
  func coolDown() {
    guard running else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    running = false
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
    lock.lock(); if capturing { samples += chunk }; lock.unlock()
  }
}
