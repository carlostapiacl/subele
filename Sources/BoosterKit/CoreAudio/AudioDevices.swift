import CoreAudio
import Foundation

/// Queries about output devices: which one the system is using, what it is
/// called, and what format it runs at.
public enum AudioDevices {

    public static func defaultOutput() throws -> AudioDeviceID {
        let device = try AudioObject.value(
            AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioDeviceID(0), describing: "read the default output device")
        guard device != kAudioObjectUnknown else {
            throw AudioError("there is no default output device")
        }
        return device
    }

    public static func uid(of device: AudioObjectID) throws -> String {
        try AudioObject.string(device, kAudioDevicePropertyDeviceUID,
                               describing: "read the device UID")
    }

    public static func name(of device: AudioObjectID) throws -> String {
        try AudioObject.string(device, kAudioObjectPropertyName,
                               describing: "read the device name")
    }

    public static func streamFormat(
        of device: AudioObjectID, scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        try AudioObject.value(device, kAudioDevicePropertyStreamFormat, scope: scope,
                              initial: AudioStreamBasicDescription(),
                              describing: "read the stream format")
    }

    /// Translates a process ID into the CoreAudio process object that taps take.
    public static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObject.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObject.system, &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "translate PID \(pid) into a process object")
        return object
    }

    /// Calls `handler` on the main queue whenever the system's default output
    /// device changes. Returns a token that removes the listener when released.
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
