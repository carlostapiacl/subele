import Foundation

public enum BoostMode: String, CaseIterable, Sendable {
    /// Gain and limiting only. Dynamics are left alone: what was loud relative to
    /// what was quiet still is. The right choice for music.
    case transparent
    /// Adds compression with makeup, which lifts the quiet parts rather than
    /// flattening the loud ones. The right choice for speech, calls, and video
    /// with weak audio.
    case loudness
}

/// The full chain: gain → [compressor + makeup] → brickwall limiter.
///
/// Two passes over the block rather than one interleaved loop. The stages are
/// sequential, so the result is identical, and keeping them apart means the
/// compressor and the limiter can be read, tested and replaced on their own.
///
/// Allocation-free and lock-free: safe to call from a CoreAudio IOProc.
public final class BoostProcessor {

    /// Input gain, linear. 1.0 leaves the signal alone, 4.0 is 400%.
    public var gain: Float = 1
    public var mode: BoostMode = .transparent

    public let compressor = Compressor()
    public let limiter = Limiter()

    private var sampleRate: Double = 48_000
    private var channels = 2

    public var outputPeak: Float { limiter.outputPeak }
    public var limiterReductionDecibels: Float { limiter.reductionDecibels }
    public var compressorReductionDecibels: Float { compressor.reductionDecibels }

    public init() {}

    public func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = min(max(channels, 1), Limiter.maximumChannels)
        compressor.prepare(sampleRate: sampleRate)
        limiter.prepare(sampleRate: sampleRate, channels: self.channels)
    }

    public func reset() {
        compressor.reset()
        limiter.reset()
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let channels = min(max(channels, 1), Limiter.maximumChannels)
        self.channels = channels

        let gain = self.gain
        let applyCompression = (mode == .loudness)

        for frame in 0..<frames {
            let base = frame * channels

            var framePeak: Float = 0
            for channel in 0..<channels {
                let raw = buffer[base + channel] * gain
                // A single NaN would poison the compressor envelope permanently:
                // NaN propagates through every comparison, so the envelope never
                // recovers and the output dies. One isFinite per sample costs
                // nothing measurable and keeps the processor bounded by design.
                let sample = raw.isFinite ? raw : 0
                buffer[base + channel] = sample
                framePeak = max(framePeak, abs(sample))
            }

            if applyCompression {
                // Stereo-linked: one gain for every channel, so the image does
                // not wander when one side is louder than the other.
                let compressorGain = compressor.gain(forPeak: framePeak)
                for channel in 0..<channels {
                    buffer[base + channel] *= compressorGain
                }
            }
        }

        limiter.process(buffer, frames: frames, channels: channels)
    }
}
