import AVFoundation
import Foundation
import Testing
@testable import V2T

/// Which microphone the session records from: its symbol, and the App Group keys the keyboard reads it from.
struct MicrophoneTests {
  let defaults = UserDefaults(suiteName: "v2t-mic-\(UUID().uuidString)")!

  @Test func eachKindOfInputGetsItsOwnSymbol() {
    let ports: [AVAudioSession.Port] = [.builtInMic, .bluetoothHFP, .bluetoothLE, .headsetMic, .carAudio, .usbAudio, .lineIn, .continuityMicrophone]

    #expect(ports.map(Recorder.symbol(for:)) == ["mic.fill", "airpods", "airpods", "headphones", "car.fill", "cable.connector", "cable.connector", "iphone"])
  }

  @Test func theKeyboardReadsTheMicrophoneTheAppWrote() {
    DictationChannel.writeMicrophone(Microphone(name: "AirPods Pro", symbol: "airpods"), to: defaults)

    #expect(DictationChannel.readMicrophone(from: defaults) == Microphone(name: "AirPods Pro", symbol: "airpods"))
  }

  @Test func noSessionClearsTheMicrophone() {
    DictationChannel.writeMicrophone(Microphone(name: "AirPods Pro", symbol: "airpods"), to: defaults)

    DictationChannel.writeMicrophone(nil, to: defaults)

    #expect(DictationChannel.readMicrophone(from: defaults) == nil)
  }

  @Test func neverWrittenReadsAsNone() {
    #expect(DictationChannel.readMicrophone(from: defaults) == nil)
  }

  /// Music from other apps must not be turned into call audio or played quieter while the session is warm.
  @Test func theSessionLeavesOtherAppsAudioAlone() {
    #expect(Recorder.options == [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
  }
}
