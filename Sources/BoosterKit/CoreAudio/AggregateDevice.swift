import CoreAudio
import Foundation

/// Un dispositivo agregado privado que junta un process tap con un dispositivo de
/// salida real.
///
/// El tap es la entrada y el hardware es la salida, así que un solo IOProc da las
/// dos puntas en el mismo callback: leer lo que el sistema está reproduciendo,
/// procesarlo, escribirlo de vuelta. El dispositivo es privado, así que nunca
/// aparece en las preferencias de Sonido y la salida elegida por el usuario queda
/// intacta.
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
                  "crear el dispositivo agregado")
        self.objectID = objectID
    }

    /// Cuántos frames entrega el dispositivo por callback. Bajarlo recorta la
    /// latencia y sube la frecuencia de despertadas; el dispositivo ajusta al
    /// valor más cercano que soporte.
    public var bufferFrameSize: UInt32 {
        get {
            AudioObject.optionalValue(objectID, kAudioDevicePropertyBufferFrameSize,
                                      initial: UInt32(0)) ?? 0
        }
        set {
            try? AudioObject.setValue(objectID, kAudioDevicePropertyBufferFrameSize,
                                      to: newValue, describing: "fijar el tamaño de buffer")
        }
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(objectID)
    }
}
