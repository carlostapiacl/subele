import CoreAudio
import Foundation

/// Captures system audio with a process tap, processes it, and returns it to the
/// same output device.
///
/// No driver is installed and the system's default output device is **not**
/// changed. The tap silences the original path for the processes it captures,
/// and we write the processed audio back to the same hardware. Our own process is
/// excluded from the tap, otherwise what we write would be captured and fed back.
///
/// ```
/// system processes ──┐
///                    ├─→ [tap, mutedWhenTapped] ──→ IOProc ──→ DSP ──┐
/// this process ──────┴──── (excluded) ───────────────────────────────┴─→ output device
/// ```
public final class BoostEngine {

    public struct Info: Sendable {
        public let deviceName: String
        public let sampleRate: Double
        public let inputChannels: Int
        public let outputChannels: Int
        public let bufferFrames: Int
    }

    public let processor = BoostProcessor()

    /// Called on the main queue when macOS changes the default output device. A
    /// tap is bound to one device, so without rebuilding the chain we would keep
    /// processing for hardware nobody is listening to any more.
    public var onDefaultOutputChanged: (() -> Void)?

    /// Frames per callback to ask the aggregate device for. Lower means less
    /// latency and more wake-ups; the device clamps to what it supports.
    /// `nil` leaves whatever CoreAudio chose.
    public var preferredBufferFrames: UInt32?

    public private(set) var isRunning = false
    public private(set) var info: Info?

    /// Measured, not estimated: the gap between the timestamp of the audio coming
    /// in and the timestamp at which it will be played, taken from the IOProc.
    public private(set) var measuredIOLatencySeconds: Double = 0

    /// Everything this chain adds on top of playing straight to the device.
    public var addedLatencySeconds: Double {
        measuredIOLatencySeconds + Double(processor.limiter.lookaheadSeconds)
    }

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var defaultOutputObserver: Any?

    /// Interleaved working buffer for gathering input and scattering output.
    /// Allocated once and kept for the life of the engine: freeing it while an
    /// IOProc could still run would be a use-after-free.
    private let maximumFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>

    public init(preferredBufferFrames: UInt32? = nil) {
        self.preferredBufferFrames = preferredBufferFrames
        scratch = .allocate(capacity: maximumFrames * Limiter.maximumChannels)
        scratch.initialize(repeating: 0, count: maximumFrames * Limiter.maximumChannels)
    }

    deinit {
        stop()
        scratch.deinitialize(count: maximumFrames * Limiter.maximumChannels)
        scratch.deallocate()
    }

    public func start() throws {
        guard !isRunning else { return }
        do { try begin() } catch { stop(); throw error }
    }

    private func begin() throws {
        trace("asking for the default output device")
        let outputDevice = try AudioDevices.defaultOutput()
        let outputUID = try AudioDevices.uid(of: outputDevice)
        let deviceName = (try? AudioDevices.name(of: outputDevice)) ?? outputUID
        trace("device: \(deviceName) uid=\(outputUID)")

        let ownProcess = try AudioDevices.processObject(for: getpid())
        trace("own process object=\(ownProcess); creating the tap")
        let tap = try ProcessTap(excluding: [ownProcess], deviceUID: outputUID)
        self.tap = tap

        trace("tap created id=\(tap.objectID); creating the aggregate device")
        let aggregate = try AggregateDevice(tapUUID: tap.uuid, outputDeviceUID: outputUID)
        self.aggregate = aggregate

        if let preferredBufferFrames {
            aggregate.bufferFrameSize = preferredBufferFrames
        }

        let inputFormat = try AudioDevices.streamFormat(
            of: aggregate.objectID, scope: kAudioObjectPropertyScopeInput)
        let outputFormat = try AudioDevices.streamFormat(
            of: aggregate.objectID, scope: kAudioObjectPropertyScopeOutput)

        guard inputFormat.mFormatID == kAudioFormatLinearPCM,
              inputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw AudioError("the tap did not deliver linear float32 audio")
        }

        let info = Info(deviceName: deviceName,
                        sampleRate: inputFormat.mSampleRate,
                        inputChannels: Int(inputFormat.mChannelsPerFrame),
                        outputChannels: Int(outputFormat.mChannelsPerFrame),
                        bufferFrames: Int(aggregate.bufferFrameSize))
        self.info = info
        trace("format \(info.sampleRate) Hz \(info.inputChannels)->\(info.outputChannels), "
              + "\(info.bufferFrames) frames per callback; installing the IOProc")

        processor.prepare(sampleRate: info.sampleRate, channels: info.outputChannels)

        try installIOProc(on: aggregate)

        try check(AudioDeviceStart(aggregate.objectID, ioProcID),
                  "start the aggregate device")

        defaultOutputObserver = AudioDevices.observeDefaultOutput { [weak self] in
            self?.onDefaultOutputChanged?()
        }
        isRunning = true
        trace("running")
    }

    private func installIOProc(on aggregate: AggregateDevice) throws {
        let processor = self.processor
        let scratch = self.scratch
        let maximumFrames = self.maximumFrames
        let maximumChannels = Limiter.maximumChannels

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate.objectID, nil) {
            [weak self] _, inputData, inputTime, outputData, outputTime in

            let output = UnsafeMutableAudioBufferListPointer(outputData)

            // Output buffers are always filled. CoreAudio does not promise they
            // arrive zeroed, so returning without writing replays whatever the
            // previous cycle left behind — which is noise.
            for buffer in output {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }

            let input = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard input.count > 0, output.count > 0 else { return }

            // Channel counts are summed across buffers: a non-interleaved device
            // presents one buffer per channel, not one buffer holding N channels.
            // Reading only buffer[0] would leave the other channels silent.
            var inputChannels = 0
            var outputChannels = 0
            var frames = Int.max
            for buffer in input {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, buffer.mData != nil else { return }
                inputChannels += channels
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            }
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, buffer.mData != nil else { return }
                outputChannels += channels
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            }
            guard frames > 0, outputChannels > 0, outputChannels <= maximumChannels
            else { return }
            frames = min(frames, maximumFrames)

            self?.recordLatency(input: inputTime, output: outputTime)

            if input.count == 1, output.count == 1, inputChannels == outputChannels {
                // The common case: one interleaved buffer at each end.
                let source = input[0].mData!.assumingMemoryBound(to: Float.self)
                let destination = output[0].mData!.assumingMemoryBound(to: Float.self)
                destination.update(from: source, count: frames * outputChannels)
                processor.process(destination, frames: frames, channels: outputChannels)
                return
            }

            // General case: gather into one interleaved buffer…
            var channel = 0
            for buffer in input {
                let channels = Int(buffer.mNumberChannels)
                let source = buffer.mData!.assumingMemoryBound(to: Float.self)
                for offset in 0..<channels where channel + offset < outputChannels {
                    let target = channel + offset
                    for frame in 0..<frames {
                        scratch[frame * outputChannels + target] =
                            source[frame * channels + offset]
                    }
                }
                channel += channels
            }
            if inputChannels < outputChannels {
                for frame in 0..<frames {
                    for channel in inputChannels..<outputChannels {
                        scratch[frame * outputChannels + channel] = 0
                    }
                }
            }

            processor.process(scratch, frames: frames, channels: outputChannels)

            // …and scatter it back out.
            channel = 0
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                let destination = buffer.mData!.assumingMemoryBound(to: Float.self)
                for offset in 0..<channels {
                    let source = channel + offset
                    for frame in 0..<frames {
                        destination[frame * channels + offset] =
                            scratch[frame * outputChannels + source]
                    }
                }
                channel += channels
            }
        }, "install the IOProc")
    }

    /// The distance between "this audio was captured" and "this audio will be
    /// heard", straight from the timestamps CoreAudio hands the callback.
    private func recordLatency(input: UnsafePointer<AudioTimeStamp>,
                               output: UnsafePointer<AudioTimeStamp>) {
        let inputStamp = input.pointee
        let outputStamp = output.pointee
        guard inputStamp.mFlags.contains(.hostTimeValid),
              outputStamp.mFlags.contains(.hostTimeValid) else { return }
        let inputNanos = AudioConvertHostTimeToNanos(inputStamp.mHostTime)
        let outputNanos = AudioConvertHostTimeToNanos(outputStamp.mHostTime)
        guard outputNanos > inputNanos else { return }
        measuredIOLatencySeconds = Double(outputNanos - inputNanos) / 1_000_000_000
    }

    public func stop() {
        defaultOutputObserver = nil
        if let ioProcID, let aggregate {
            AudioDeviceStop(aggregate.objectID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.objectID, ioProcID)
        }
        ioProcID = nil
        // Order matters: the aggregate references the tap, so it goes first.
        // Both destroy themselves in deinit.
        aggregate = nil
        tap = nil
        info = nil
        isRunning = false
    }
}
