import CoreAudio
import Foundation

/// Consultas sobre dispositivos de salida: cuál está usando el sistema, cómo se
/// llama y a qué formato corre.
public enum AudioDevices {

    public static func defaultOutput() throws -> AudioDeviceID {
        let device = try AudioObject.value(
            AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioDeviceID(0), describing: "leer el dispositivo de salida por defecto")
        guard device != kAudioObjectUnknown else {
            throw AudioError("no hay dispositivo de salida por defecto")
        }
        return device
    }

    public static func uid(of device: AudioObjectID) throws -> String {
        try AudioObject.string(device, kAudioDevicePropertyDeviceUID,
                               describing: "leer el UID del dispositivo")
    }

    public static func name(of device: AudioObjectID) throws -> String {
        try AudioObject.string(device, kAudioObjectPropertyName,
                               describing: "leer el nombre del dispositivo")
    }

    public static func streamFormat(
        of device: AudioObjectID, scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        try AudioObject.value(device, kAudioDevicePropertyStreamFormat, scope: scope,
                              initial: AudioStreamBasicDescription(),
                              describing: "leer el formato del stream")
    }

    /// Traduce un ID de proceso al objeto de proceso de CoreAudio que piden los taps.
    public static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObject.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObject.system, &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "traducir el PID \(pid) a objeto de proceso")
        return object
    }

    /// Llama a `handler` en la cola principal cada vez que cambia el dispositivo de
    /// salida por defecto. Devuelve un token que quita el listener al soltarse.
    public static func observeDefaultOutput(_ handler: @escaping () -> Void) -> Any? {
        var address = AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObject.system, &address, DispatchQueue.main, block)
        guard status == noErr else { return nil }
        return DefaultOutputObserver(block: block)
    }

    private final class DefaultOutputObserver {
        private let block: AudioObjectPropertyListenerBlock
        init(block: @escaping AudioObjectPropertyListenerBlock) { self.block = block }
        deinit {
            var address = AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObject.system, &address, DispatchQueue.main, block)
        }
    }
}
