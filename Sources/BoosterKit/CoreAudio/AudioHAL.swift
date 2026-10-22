import CoreAudio
import Foundation

/// Todo lo que el motor le pide a CoreAudio, detrás de un protocolo.
///
/// Existe para poder testear el motor sin hardware: los tests usan una HAL falsa
/// que entrega formatos raros, interfaces dúplex, agregados que tardan en estar
/// listos o un `AudioDeviceStop` que falla, y cuenta qué quedó vivo al final. La
/// implementación real, `SystemAudioHAL`, es una capa delgada sobre la API de C.
///
/// Las destrucciones devuelven `OSStatus` en vez de lanzar: el teardown tiene que
/// seguir aunque un paso falle, y quien lo llama decide qué registrar.
public protocol AudioHAL: AnyObject {
    func defaultOutputDevice() throws -> AudioDeviceID
    func uid(of device: AudioObjectID) throws -> String
    func name(of device: AudioObjectID) throws -> String
    func ownProcessObject() throws -> AudioObjectID

    /// Formato del primer stream de un lado del dispositivo.
    func streamFormat(of device: AudioObjectID,
                      scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription
    /// Canales de cada buffer de un lado del dispositivo, en el orden en que
    /// llegan al IOProc. Vacío si ese lado no tiene streams.
    func streamLayout(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int]

    func createTap(excluding processes: [AudioObjectID],
                   deviceUID: String) throws -> (id: AudioObjectID, uuid: UUID)
    func tapFormat(of tap: AudioObjectID) throws -> AudioStreamBasicDescription
    func destroyTap(_ tap: AudioObjectID) -> OSStatus

    func createAggregate(tapUUID: UUID, outputDeviceUID: String) throws -> AudioDeviceID
    func destroyAggregate(_ device: AudioDeviceID) -> OSStatus
    func bufferFrameSize(of device: AudioDeviceID) -> UInt32
    func setBufferFrameSize(_ frames: UInt32, of device: AudioDeviceID)

    func createIOProc(on device: AudioDeviceID,
                      _ block: @escaping AudioDeviceIOBlock) throws -> IOProcHandle
    func startIO(_ handle: IOProcHandle) throws
    func stopIO(_ handle: IOProcHandle) -> OSStatus
    func destroyIOProc(_ handle: IOProcHandle) -> OSStatus

    /// Llama a `handler` en la cola principal cada vez que cambia la propiedad.
    /// El listener se quita al soltar el token.
    func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope,
                 _ handler: @escaping () -> Void) -> AnyObject?
}

/// Un IOProc instalado. En la HAL real lleva el ID de CoreAudio; la falsa lo usa
/// como llave.
public final class IOProcHandle {
    public let device: AudioDeviceID
    let procID: AudioDeviceIOProcID?

    public init(device: AudioDeviceID, procID: AudioDeviceIOProcID? = nil) {
        self.device = device
        self.procID = procID
    }
}

/// La HAL de verdad.
public final class SystemAudioHAL: AudioHAL {

    public init() {}

    public func defaultOutputDevice() throws -> AudioDeviceID { try AudioDevices.defaultOutput() }
    public func uid(of device: AudioObjectID) throws -> String { try AudioDevices.uid(of: device) }
    public func name(of device: AudioObjectID) throws -> String { try AudioDevices.name(of: device) }

    public func ownProcessObject() throws -> AudioObjectID {
        try AudioDevices.processObject(for: getpid())
    }

    public func streamFormat(of device: AudioObjectID,
                             scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        try AudioDevices.streamFormat(of: device, scope: scope)
    }

    public func streamLayout(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        AudioDevices.streamLayout(of: device, scope: scope)
    }

    public func createTap(excluding processes: [AudioObjectID],
                          deviceUID: String) throws -> (id: AudioObjectID, uuid: UUID) {
        try ProcessTap.create(excluding: processes, deviceUID: deviceUID)
    }

    public func tapFormat(of tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try ProcessTap.format(of: tap)
    }

    public func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tap)
    }

    public func createAggregate(tapUUID: UUID, outputDeviceUID: String) throws -> AudioDeviceID {
        try AggregateDevice.create(tapUUID: tapUUID, outputDeviceUID: outputDeviceUID)
    }

    public func destroyAggregate(_ device: AudioDeviceID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(device)
    }

    public func bufferFrameSize(of device: AudioDeviceID) -> UInt32 {
        AudioObject.optionalValue(device, kAudioDevicePropertyBufferFrameSize,
                                  initial: UInt32(0)) ?? 0
    }

    public func setBufferFrameSize(_ frames: UInt32, of device: AudioDeviceID) {
        // El dispositivo ajusta al valor más cercano que soporte; si no acepta
        // ninguno, queda el suyo, que también sirve.
        try? AudioObject.setValue(device, kAudioDevicePropertyBufferFrameSize,
                                  to: frames, describing: "fijar el tamaño de buffer")
    }

    public func createIOProc(on device: AudioDeviceID,
                             _ block: @escaping AudioDeviceIOBlock) throws -> IOProcHandle {
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil, block),
                  "instalar el IOProc")
        return IOProcHandle(device: device, procID: procID)
    }

    public func startIO(_ handle: IOProcHandle) throws {
        try check(AudioDeviceStart(handle.device, handle.procID), "arrancar el dispositivo agregado")
    }

    public func stopIO(_ handle: IOProcHandle) -> OSStatus {
        AudioDeviceStop(handle.device, handle.procID)
    }

    public func destroyIOProc(_ handle: IOProcHandle) -> OSStatus {
        guard let procID = handle.procID else { return noErr }
        return AudioDeviceDestroyIOProcID(handle.device, procID)
    }

    public func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope,
                        _ handler: @escaping () -> Void) -> AnyObject? {
        AudioDevices.observe(object, selector, scope: scope, handler)
    }
}
