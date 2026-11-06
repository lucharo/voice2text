import AVFoundation
import Foundation
import Testing
@testable import V2T

/// Which microphone the session records from: the App Group keys the keyboard reads it from.
struct MicrophoneTests {
  let defaults = UserDefaults(suiteName: "v2t-mic-\(UUID().uuidString)")!

  @Test func theKeyboardReadsTheMicrophoneTheAppWrote() {
    DictationChannel.writeMicrophone(Microphone(name: "Headset Microphone"), to: defaults)

    #expect(DictationChannel.readMicrophone(from: defaults) == Microphone(name: "Headset Microphone"))
  }

  @Test func noSessionClearsTheMicrophone() {
    DictationChannel.writeMicrophone(Microphone(name: "Headset Microphone"), to: defaults)

    DictationChannel.writeMicrophone(nil, to: defaults)

    #expect(DictationChannel.readMicrophone(from: defaults) == nil)
  }

  @Test func neverWrittenReadsAsNone() {
    #expect(DictationChannel.readMicrophone(from: defaults) == nil)
  }

  /// With the iPhone's microphone (the default), music on Bluetooth headphones must not turn into call audio.
  @Test func theIPhoneMicrophoneLeavesHeadphonesInMusicMode() {
    #expect(Recorder.options(for: .iPhone) == [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
  }

  @Test func theConnectedMicrophoneAllowsABluetoothHeadset() {
    #expect(Recorder.options(for: .connected) == [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay, .allowBluetoothHFP])
  }

  @Test func theIPhoneMicrophoneIsTheDefault() {
    #expect(Settings(defaults: defaults).microphoneChoice == .iPhone)
  }
}
