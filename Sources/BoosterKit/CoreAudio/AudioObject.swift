import CoreAudio
import Foundation

/// Un error de una llamada a CoreAudio.
///
/// Los `OSStatus` de acá son códigos de cuatro caracteres. Impresos en decimal no
/// dicen nada, así que el código siempre se devuelve a sus caracteres.
public struct AudioError: LocalizedError {
    public let message: String
    public let status: OSStatus?

    public init(_ message: String, status: OSStatus? = nil) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? {
        guard let status else { return message }
        return "\(message) — OSStatus \(status) (\(fourCharCode(status)))"
    }
}

/// Reconstruye un `OSStatus` en los cuatro caracteres con que fue armado, y cae al
/// número cuando los bytes no son imprimibles.
public func fourCharCode(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                 UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    guard let text = String(bytes: bytes, encoding: .ascii),
          text.allSatisfy({ $0.isASCII && $0.asciiValue.map { $0 >= 32 } == true })
    else { return String(status) }
    return "'\(text)'"
}

@discardableResult
func check(_ status: OSStatus, _ what: String) throws -> OSStatus {
    guard status == noErr else { throw AudioError(what, status: status) }
    return status
}

/// Envoltorio tipado y delgado sobre la familia `AudioObjectGetPropertyData`.
///
/// Todas las llamadas de esa API tienen la misma forma de seis argumentos, con un
/// tamaño por referencia y un puntero crudo. Envolverla una vez deja esa forma
/// fuera del resto del código.
public enum AudioObject {

    public static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Lee una propiedad de tamaño fijo en un valor de tipo `T`.
    static func value<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T,
        describing what: String
    ) throws -> T {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), what)
        return value
    }

    /// Lee una propiedad de tamaño fijo devolviendo nil en vez de lanzar, para
    /// valores que son informativos pero no imprescindibles, como la latencia.
    static func optionalValue<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        try? value(objectID, selector, scope: scope, initial: initial, describing: "")
    }

    /// Escribe una propiedad de tamaño fijo.
    static func setValue<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        to value: T,
        describing what: String
    ) throws {
        var address = address(selector, scope: scope)
        var value = value
        try check(AudioObjectSetPropertyData(objectID, &address, 0, nil,
                                             UInt32(MemoryLayout<T>.size), &value), what)
    }

    /// Lee una propiedad `CFString`. CoreAudio devuelve una referencia con +1, que
    /// el `CFString?` local pasa a poseer y después libera — las cuentas cierran.
    static func string(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        describing what: String
    ) throws -> String {
        var address = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }, what)
        guard let string = value as String? else { throw AudioError(what) }
        return string
    }
}

/// Traza sin búfer a stderr, se enciende con `BOOSTER_TRACE=1`.
///
/// Las llamadas a CoreAudio pueden bloquearse indefinidamente sin devolver error
/// — un tap sobre un dispositivo que es dueño otro driver virtual hace exactamente
/// eso. Con stdout bufferizado, un cuelgue así no deja ningún rastro, así que los
/// pasos se marcan por acá.
public func trace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["BOOSTER_TRACE"] != nil else { return }
    FileHandle.standardError.write("[trace] \(message())\n".data(using: .utf8)!)
}
