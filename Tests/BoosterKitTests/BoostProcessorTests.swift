import Foundation
import Testing
@testable import BoosterKit

@Suite("BoostProcessor")
struct BoostProcessorTests {

    @Test("gain is exact while there is headroom", arguments: [
        (gain: Float(1), expected: Float(-20)),
        (gain: Float(3), expected: Float(-10.46)),
        (gain: Float(4), expected: Float(-7.96)),
    ])
    func gainIsExact(gain: Float, expected: Float) {
        let processor = makeProcessor(gain: gain, mode: .transparent)
        let output = render(processor, sine(decibels: -20, frames: 48_000, channels: 2),
                            channels: 2)
        #expect(abs(linearToDecibels(steadyStatePeak(output, channels: 2)) - expected) < 0.2)
    }

    @Test("loudness mode lifts quiet material")
    func loudnessLifts() {
        let input = sine(decibels: -20, frames: 48_000, channels: 2)
        let transparent = render(makeProcessor(gain: 1, mode: .transparent), input, channels: 2)
        let loudness = render(makeProcessor(gain: 1, mode: .loudness), input, channels: 2)
        let lift = linearToDecibels(steadyStatePeak(loudness, channels: 2))
                 - linearToDecibels(steadyStatePeak(transparent, channels: 2))
        // −18 dB threshold at 4:1 leaves +13.5 dB of makeup, minus what the curve
        // takes off a −20 dBFS signal inside the knee.
        #expect(abs(lift - 13.44) < 0.3)
    }

    @Test("the result does not depend on the block size CoreAudio hands over")
    func blockSizeInvariant() {
        // If this ever differs, state is being lost or reset between blocks.
        let channels = 2
        let frames = 12_000
        var input = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let envelope = 0.5 + 0.5 * sinf(2 * .pi * 3 * Float(frame) / 48_000)
            let value = envelope * sinf(2 * .pi * 440 * Float(frame) / 48_000)
            for channel in 0..<channels { input[frame * channels + channel] = value }
        }
        let small = render(makeProcessor(gain: 2.5, mode: .loudness), input,
                           channels: channels, blockSize: 32)
        let large = render(makeProcessor(gain: 2.5, mode: .loudness), input,
                           channels: channels, blockSize: 1024)
        #expect(zip(small, large).allSatisfy { $0 == $1 })
    }

    @Test("bounded for any channel count", arguments: [1, 2, 4, 6, 8])
    func boundedForEveryChannelCount(channels: Int) {
        // The delay line uses a fixed stride, so an unusual channel count is
        // exactly where an index would run off the end.
        let processor = makeProcessor(gain: 3, mode: .loudness, channels: channels)
        let output = render(processor, sine(decibels: -6, frames: 4_800, channels: channels),
                            channels: channels)
        #expect(peak(output) > 0)
        #expect(linearToDecibels(peak(output)) <= ceilingDecibels + 0.05)
    }

    @Test("NaN and infinity cannot poison the chain")
    func survivesNonFiniteInput() {
        // A single NaN propagates through every comparison. Without sanitising,
        // the compressor envelope never recovers and the output dies for good.
        let channels = 2
        var input = sine(decibels: -12, frames: 4_800, channels: channels)
        input[100] = .nan
        input[101] = .infinity
        input[102] = -.infinity
        let output = render(makeProcessor(gain: 2, mode: .loudness), input, channels: channels)

        #expect(output.allSatisfy { $0.isFinite })
        // Still alive afterwards: a dead output would also be finite.
        let tail = Array(output[(output.count / 2)...])
        #expect(peak(tail) > 0.01)
    }

    @Test("silence in, silence out")
    func silenceStaysSilent() {
        let processor = makeProcessor(gain: 4, mode: .loudness)
        let output = render(processor, [Float](repeating: 0, count: 9_600), channels: 2)
        #expect(peak(output) == 0)
    }
}
