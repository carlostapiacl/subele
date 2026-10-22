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
///
/// Ojo: el subdispositivo entra entero, con sus entradas si las tiene. La entrada
/// del agregado es entonces "entradas físicas + tap", y el que separa una cosa de
/// la otra es `IORenderer.tapBufferRange`.
enum AggregateDevice {

    static func create(tapUUID: UUID, outputDeviceUID: String,
                       name: String = "Subele") throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "cl.carlostapia.subele.\(UUID().uuidString)",
            // El hardware real es el reloj: el tap se ajusta a él, no al revés.
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
        return objectID
    }
}
