import Foundation

/// A brickwall limiter with lookahead. This is the piece that justifies the
/// project: it is what lets the gain go up without the sound falling apart.
///
/// A booster that only multiplies clips — it shears the tops off the waveform,
/// and that is the tinny sound people associate with "volume boosters". The fix
/// is to see the peak before it arrives and to be already turned down when it
/// does. Concretely:
///
/// 1. The signal is delayed by `lookaheadSeconds`.
/// 2. For every incoming frame, the gain that frame would need is computed.
/// 3. A **monotonic queue** keeps the running minimum of those gains over the
///    whole lookahead window, in amortised O(1) per sample.
/// 4. The frame leaving the delay line is multiplied by the lowest gain that any
///    frame between it and the present will require.
///
/// Step 3 is the part that is easy to get wrong. Smoothing the gain with attack
/// and release instead of taking the window minimum lets the release creep the
/// gain back up during the lookahead, and the limiter overshoots by a few tenths
/// of a dB — enough to hit full scale and clip. With the window minimum,
/// overshoot is impossible by construction rather than by tuning.
public final class Limiter {

    public static let maximumChannels = 8
    private static let maximumLookaheadFrames = 2048

    public var ceilingDecibels: Float = -0.3 {
        didSet { ceiling = decibelsToLinear(ceilingDecibels) }
    }
    public var lookaheadSeconds: Float = 0.003
    public var releaseSeconds: Float = 0.080

    private var ceiling: Float = decibelsToLinear(-0.3)
    private var releaseCoefficient: Float = 0
    private var gain: Float = 1
    private var channels = 2

    /// Circular delay line, interleaved with a fixed stride of `maximumChannels`
    /// so that a change in channel count cannot move existing frames.
    private let delayLine: UnsafeMutablePointer<Float>
    private let delayCapacityFrames = Limiter.maximumLookaheadFrames
    private var lookaheadFrames = 0
    private var writeIndex = 0

    /// Monotonic queue holding the sliding-window minimum of the target gains.
    /// Capacity covers the window (lookahead + 1), the transient extra element
    /// pushed before the front is dropped, and the slot a circular buffer must
    /// leave free to tell full from empty.
    private let queueIndex: UnsafeMutablePointer<Int>
    private let queueValue: UnsafeMutablePointer<Float>
    private let queueCapacity = Limiter.maximumLookaheadFrames + 8
    private var queueHead = 0
    private var queueTail = 0
    private var sampleCounter = 0

    /// Lowest gain applied during the last processed block, in dB (<= 0).
    public private(set) var reductionDecibels: Float = 0
    /// Peak of the last processed block, linear.
    public private(set) var outputPeak: Float = 0

    public init() {
        let frames = Limiter.maximumLookaheadFrames
        delayLine = .allocate(capacity: frames * Limiter.maximumChannels)
        delayLine.initialize(repeating: 0, count: frames * Limiter.maximumChannels)
        queueIndex = .allocate(capacity: queueCapacity)
        queueIndex.initialize(repeating: 0, count: queueCapacity)
        queueValue = .allocate(capacity: queueCapacity)
        queueValue.initialize(repeating: 1, count: queueCapacity)
        prepare(sampleRate: 48_000, channels: 2)
    }

    deinit {
        delayLine.deinitialize(count: delayCapacityFrames * Limiter.maximumChannels)
        delayLine.deallocate()
        queueIndex.deinitialize(count: queueCapacity)
        queueIndex.deallocate()
        queueValue.deinitialize(count: queueCapacity)
        queueValue.deallocate()
    }

    public func prepare(sampleRate: Double, channels: Int) {
        self.channels = min(max(channels, 1), Limiter.maximumChannels)
        ceiling = decibelsToLinear(ceilingDecibels)
        lookaheadFrames = min(Int(lookaheadSeconds * Float(sampleRate)),
                              Limiter.maximumLookaheadFrames - 1)
        releaseCoefficient = smoothingCoefficient(seconds: releaseSeconds,
                                                  sampleRate: Float(sampleRate))
        reset()
    }

    public func reset() {
        delayLine.update(repeating: 0, count: delayCapacityFrames * Limiter.maximumChannels)
        writeIndex = 0
        queueHead = 0
        queueTail = 0
        sampleCounter = 0
        gain = 1
        reductionDecibels = 0
        outputPeak = 0
    }

    /// Processes interleaved audio in place. Allocation-free and lock-free: safe
    /// to call from a CoreAudio IOProc.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        // Never call prepare() from here — it memsets the delay line, which does
        // not belong in a real-time callback. A changed channel count is simply
        // adopted; the delay line flushes itself within one lookahead window.
        let channels = min(max(channels, 1), Limiter.maximumChannels)
        self.channels = channels

        let stride = Limiter.maximumChannels
        var lowestGain: Float = 1
        var peak: Float = 0

        for frame in 0..<frames {
            let base = frame * channels

            var framePeak: Float = 0
            for channel in 0..<channels {
                framePeak = max(framePeak, abs(buffer[base + channel]))
            }

            // Delay line: store the incoming frame, locate the outgoing one.
            let writeBase = writeIndex * stride
            let readIndex = (writeIndex + delayCapacityFrames - lookaheadFrames)
                % delayCapacityFrames
            let readBase = readIndex * stride
            for channel in 0..<channels {
                delayLine[writeBase + channel] = buffer[base + channel]
            }
            writeIndex = (writeIndex + 1) % delayCapacityFrames

            // Sliding-window minimum of the target gain.
            let target: Float = framePeak > ceiling ? ceiling / framePeak : 1
            while queueTail != queueHead {
                let back = (queueTail + queueCapacity - 1) % queueCapacity
                if queueValue[back] >= target { queueTail = back } else { break }
            }
            queueIndex[queueTail] = sampleCounter
            queueValue[queueTail] = target
            queueTail = (queueTail + 1) % queueCapacity
            while queueIndex[queueHead] < sampleCounter - lookaheadFrames {
                queueHead = (queueHead + 1) % queueCapacity
            }
            let windowMinimum = queueValue[queueHead]
            sampleCounter += 1

            // Turning down is immediate — the lookahead already moved it early.
            // Coming back up is smoothed so the gain does not zipper.
            if windowMinimum < gain {
                gain = windowMinimum
            } else {
                gain = windowMinimum + releaseCoefficient * (gain - windowMinimum)
            }
            lowestGain = min(lowestGain, gain)

            for channel in 0..<channels {
                let sample = max(-1, min(1, delayLine[readBase + channel] * gain))
                buffer[base + channel] = sample
                peak = max(peak, abs(sample))
            }
        }

        outputPeak = peak
        reductionDecibels = linearToDecibels(lowestGain)
    }
}
