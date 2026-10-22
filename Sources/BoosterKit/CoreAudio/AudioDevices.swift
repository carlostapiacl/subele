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

    // MARK: Frecuencia de muestreo

    /// La frecuencia a la que corre el dispositivo, la misma que muestra
    /// Configuración de Audio MIDI.
    public static func nominalSampleRate(of device: AudioObjectID) throws -> Double {
        try AudioObject.value(device, kAudioDevicePropertyNominalSampleRate,
                              initial: Float64(0),
                              describing: "leer la frecuencia de muestreo")
    }

    /// Cambia la frecuencia del dispositivo para todo el sistema, igual que
    /// hacerlo a mano en Configuración de Audio MIDI. El cambio es asíncrono: el
    /// dispositivo avisa cuando lo terminó de aplicar.
    public static func setNominalSampleRate(_ rate: Double, of device: AudioObjectID) throws {
        try AudioObject.setValue(device, kAudioDevicePropertyNominalSampleRate,
                                 to: Float64(rate),
                                 describing: "cambiar la frecuencia de muestreo a \(Int(rate)) Hz")
    }

    /// Frecuencias que el dispositivo acepta, de menor a mayor.
    ///
    /// CoreAudio las entrega como rangos. Casi siempre cada rango es un solo valor,
    /// pero algunas interfaces declaran un rango continuo; de esos se ofrecen las
    /// frecuencias estándar que caen adentro, no infinitas opciones.
    public static func availableSampleRates(of device: AudioObjectID) -> [Double] {
        var address = AudioObject.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.stride
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr
        else { return [] }

        let standard: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                for rate in standard where rate >= range.mMinimum && rate <= range.mMaximum {
                    rates.insert(rate)
                }
            }
        }
        return rates.sorted()
    }

    // MARK: Streams

    /// Canales de cada buffer de un lado del dispositivo, en el orden en que
    /// llegan al IOProc. Vacío si ese lado no tiene streams o no se puede leer.
    public static func streamLayout(of device: AudioObjectID,
                                    scope: AudioObjectPropertyScope) -> [Int] {
        var address = AudioObject.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    // MARK: Observadores

    /// Llama a `handler` en la cola principal cada vez que cambia la propiedad.
    /// Devuelve un token que quita el listener al soltarse, o nil si CoreAudio no
    /// aceptó el listener.
    public static func observe(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ handler: @escaping () -> Void) -> AnyObject? {
        var address = AudioObject.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(
            object, &address, DispatchQueue.main, block)
        guard status == noErr else { return nil }
        return PropertyObserver(object: object, address: address, block: block)
    }

    private final class PropertyObserver {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        init(object: AudioObjectID, address: AudioObjectPropertyAddress,
             block: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object
            self.address = address
            self.block = block
        }
        deinit {
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }
}
