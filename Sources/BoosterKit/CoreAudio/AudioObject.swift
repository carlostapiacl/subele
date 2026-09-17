import CoreAudio
import Foundation

/// An error from a CoreAudio call.
///
/// `OSStatus` values here are four-character codes. Printed as a decimal they
/// tell you nothing, so the code is always rendered back into its characters.
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

/// Renders an `OSStatus` back into the four characters it was built from,
/// falling back to the number when the bytes are not printable.
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

/// A thin, typed wrapper over the `AudioObjectGetPropertyData` family.
///
/// Every call in that API is the same six-argument shape with an inout size and
/// a raw pointer. Wrapping it once keeps that shape out of the rest of the code.
public enum AudioObject {

    public static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size property into a value of type `T`.
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

    /// Reads a fixed-size property, returning nil instead of throwing.
    /// For values that are informative but not required, such as latency.
    static func optionalValue<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        try? value(objectID, selector, scope: scope, initial: initial, describing: "")
    }

    /// Writes a fixed-size property.
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

    /// Reads a `CFString` property. CoreAudio hands back a +1 reference, which
    /// the local `CFString?` then owns and releases — the counts balance.
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

/// Unbuffered tracing to stderr, enabled with `BOOSTER_TRACE=1`.
///
/// CoreAudio calls can block indefinitely without returning an error — a tap on a
/// device owned by another virtual driver does exactly that. When stdout is
/// buffered such a hang leaves no trace at all, so the steps are marked here.
public func trace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["BOOSTER_TRACE"] != nil else { return }
    FileHandle.standardError.write("[trace] \(message())\n".data(using: .utf8)!)
}
