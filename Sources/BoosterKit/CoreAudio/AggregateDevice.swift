import CoreAudio
import Foundation

/// A private aggregate device that pairs a process tap with a real output device.
///
/// The tap is the input and the hardware is the output, so a single IOProc gives
/// both ends in one callback: read what the system is playing, process it, write
/// it back out. The device is private, so it never shows up in Sound preferences
/// and the user's chosen output is left alone.
public final class AggregateDevice {

    public let objectID: AudioDeviceID

    public init(tapUUID: UUID, outputDeviceUID: String, name: String = "Audio Booster") throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "cl.carlostapia.audio-booster.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true,
                 kAudioSubTapUIDKey: tapUUID.uuidString]
            ],
        ]

        var objectID = AudioDeviceID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &objectID),
                  "create the aggregate device")
        self.objectID = objectID
    }

    /// The number of frames the device hands over per callback. Lowering it cuts
    /// latency and raises the wake-up rate; the device clamps to what it supports.
    public var bufferFrameSize: UInt32 {
        get {
            AudioObject.optionalValue(objectID, kAudioDevicePropertyBufferFrameSize,
                                      initial: UInt32(0)) ?? 0
        }
        set {
            try? AudioObject.setValue(objectID, kAudioDevicePropertyBufferFrameSize,
                                      to: newValue, describing: "set the buffer frame size")
        }
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(objectID)
    }
}
