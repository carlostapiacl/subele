import CoreAudio
import Foundation

/// Un process tap de CoreAudio: la API pública, disponible desde macOS 14.2, que
/// captura lo que otros procesos están mandando a un dispositivo de salida.
///
/// Es lo que hace posible todo el proyecto sin instalar driver. La forma vieja
/// —la que usan Boom 3D y eqMac— es instalar un `AudioServerPlugIn` en
/// `/Library/Audio/Plug-Ins/HAL`, ponerse como salida por defecto del sistema y
/// pasar el audio a través. Un tap no necesita nada de eso.
///
/// Dos ajustes importan:
///
/// - `.mutedWhenTapped` silencia el camino original de cada proceso tapeado, así
///   el audio se escucha una vez —a través nuestro— y no dos.
/// - Excluir nuestro propio proceso nos deja fuera de nuestro propio tap. Sin eso,
///   lo que escribimos al dispositivo se capturaría y volvería a entrar.
public final class ProcessTap {

    public let objectID: AudioObjectID
    public let uuid: UUID

    /// Tapea todo lo que va a `deviceUID` menos los procesos indicados.
    public init(excluding processes: [AudioObjectID], deviceUID: String, stream: Int = 0) throws {
        let description = CATapDescription(
            __excludingProcesses: processes.map { NSNumber(value: $0) },
            andDeviceUID: deviceUID,
            withStream: stream)
        description.name = "Audio Booster"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var objectID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &objectID),
                  "crear el process tap")
        guard objectID != kAudioObjectUnknown else {
            throw AudioError("el process tap se creó vacío")
        }
        self.objectID = objectID
        self.uuid = description.uuid
    }

    deinit {
        AudioHardwareDestroyProcessTap(objectID)
    }
}
