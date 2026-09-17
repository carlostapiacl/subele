import CoreAudio
import Foundation

/// A CoreAudio process tap: the public API, available since macOS 14.2, that
/// captures what other processes are sending to an output device.
///
/// This is what makes the whole project possible without a driver. The older way
/// — what Boom 3D and eqMac do — is to install an `AudioServerPlugIn` into
/// `/Library/Audio/Plug-Ins/HAL`, take over the system's default output, and pass
/// audio through. A tap needs none of that.
///
/// Two settings matter:
///
/// - `.mutedWhenTapped` silences the original path for every tapped process, so
///   the audio is heard once — through us — rather than twice.
/// - Excluding our own process keeps us out of our own tap. Without it, what we
///   write to the device would be captured and fed back in.
public final class ProcessTap {

    public let objectID: AudioObjectID
    public let uuid: UUID

    /// Taps everything going to `deviceUID` except the given processes.
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
                  "create the process tap")
        guard objectID != kAudioObjectUnknown else {
            throw AudioError("the process tap was created empty")
        }
        self.objectID = objectID
        self.uuid = description.uuid
    }

    deinit {
        AudioHardwareDestroyProcessTap(objectID)
    }
}
