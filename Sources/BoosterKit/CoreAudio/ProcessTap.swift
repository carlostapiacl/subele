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
///
/// No es una clase con `deinit`: la destrucción la hace el motor de forma
/// explícita, en orden y mirando el resultado (ver `BoostEngine.stop`).
enum ProcessTap {

    /// Tapea todo lo que va a `deviceUID` menos los procesos indicados.
    static func create(excluding processes: [AudioObjectID], deviceUID: String,
                       stream: Int = 0) throws -> (id: AudioObjectID, uuid: UUID) {
        let description = CATapDescription(
            __excludingProcesses: processes.map { NSNumber(value: $0) },
            andDeviceUID: deviceUID,
            withStream: stream)
        description.name = "Subele"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var objectID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &objectID),
                  "crear el process tap")
        guard objectID != kAudioObjectUnknown else {
            throw AudioError("el process tap se creó vacío")
        }
        return (objectID, description.uuid)
    }

    /// El formato en que el tap entrega el audio. Es el que hay que validar, no
    /// el de la entrada del agregado: ese es el del primer stream de entrada, que
    /// en una interfaz con micrófono es el micrófono.
    static func format(of tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try AudioObject.value(tap, kAudioTapPropertyFormat,
                              initial: AudioStreamBasicDescription(),
                              describing: "leer el formato del tap")
    }
}
