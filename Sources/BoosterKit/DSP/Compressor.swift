import Foundation

/// A soft-knee downward compressor, used here as a gain computer: it answers
/// "what should this frame be multiplied by", and the caller applies it.
///
/// The threshold is deliberately high. A compressor exists here to tame what is
/// approaching the ceiling, not to flatten everything — and **makeup gain is not
/// optional**. Without it a compressor makes audio quieter, which is the opposite
/// of what a booster is for. Makeup is derived from the curve itself: whatever
/// the compressor would take off a full-scale signal is given back to everything.
public final class Compressor {

    public var thresholdDecibels: Float = -18
    public var ratio: Float = 4
    public var kneeDecibels: Float = 6
    public var attackSeconds: Float = 0.010
    public var releaseSeconds: Float = 0.120

    private var attackCoefficient: Float = 0
    private var releaseCoefficient: Float = 0
    private var envelopeDecibels: Float = 0

    /// Linear gain that compensates the curve, computed in `prepare`.
    public private(set) var makeup: Float = 1

    /// Gain reduction currently applied, in dB (<= 0). For metering.
    public var reductionDecibels: Float { envelopeDecibels }

    public init() { prepare(sampleRate: 48_000) }

    public func prepare(sampleRate: Double) {
        let rate = Float(sampleRate)
        attackCoefficient = smoothingCoefficient(seconds: attackSeconds, sampleRate: rate)
        releaseCoefficient = smoothingCoefficient(seconds: releaseSeconds, sampleRate: rate)
        makeup = decibelsToLinear(-staticReductionDecibels(forLevel: 0))
        reset()
    }

    public func reset() {
        envelopeDecibels = 0
    }

    /// The static curve, without time constants: gain reduction in dB for a level.
    /// Separated out so it can be tested on its own and so `prepare` can ask what
    /// the curve does at full scale in order to derive makeup.
    public func staticReductionDecibels(forLevel levelDecibels: Float) -> Float {
        let over = levelDecibels - thresholdDecibels
        let halfKnee = kneeDecibels / 2
        if over <= -halfKnee { return 0 }
        let slope = 1 / ratio - 1
        if over >= halfKnee { return slope * over }
        // Knee: quadratic interpolation, continuous in value and slope at both ends.
        let x = over + halfKnee
        return slope * x * x / (2 * kneeDecibels)
    }

    /// Smoothed linear gain for a frame, makeup included.
    @inline(__always)
    public func gain(forPeak peak: Float) -> Float {
        let target = staticReductionDecibels(forLevel: linearToDecibels(peak))
        let coefficient = target < envelopeDecibels ? attackCoefficient : releaseCoefficient
        envelopeDecibels = target + coefficient * (envelopeDecibels - target)
        return decibelsToLinear(envelopeDecibels) * makeup
    }
}
