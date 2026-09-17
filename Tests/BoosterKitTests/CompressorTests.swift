import Testing
@testable import BoosterKit

@Suite("Compressor")
struct CompressorTests {

    @Test("below the threshold nothing is touched")
    func belowThreshold() {
        let compressor = Compressor()
        #expect(compressor.staticReductionDecibels(forLevel: -40) == 0)
        #expect(compressor.staticReductionDecibels(forLevel: -30) == 0)
    }

    @Test("above the knee the curve follows the ratio")
    func aboveKnee() {
        let compressor = Compressor()   // threshold -18, ratio 4:1, knee 6
        // 18 dB over the threshold at 4:1 gives back a quarter: −13.5 dB.
        #expect(abs(compressor.staticReductionDecibels(forLevel: 0) - -13.5) < 0.01)
    }

    @Test("the knee is continuous at both ends")
    func kneeIsContinuous() {
        let compressor = Compressor()
        let halfKnee = compressor.kneeDecibels / 2
        let lower = compressor.thresholdDecibels - halfKnee
        let upper = compressor.thresholdDecibels + halfKnee
        // Approaching the knee from outside must meet the knee's own value.
        #expect(abs(compressor.staticReductionDecibels(forLevel: lower - 0.001)
                    - compressor.staticReductionDecibels(forLevel: lower + 0.001)) < 0.01)
        #expect(abs(compressor.staticReductionDecibels(forLevel: upper - 0.001)
                    - compressor.staticReductionDecibels(forLevel: upper + 0.001)) < 0.01)
    }

    @Test("makeup gives back exactly what the curve takes at full scale")
    func makeupCompensatesTheCurve() {
        let compressor = Compressor()
        compressor.prepare(sampleRate: 48_000)
        let takenAtFullScale = compressor.staticReductionDecibels(forLevel: 0)
        #expect(abs(linearToDecibels(compressor.makeup) + takenAtFullScale) < 0.01)
    }

    @Test("a compressor without makeup would make audio quieter")
    func makeupIsNotOptional() {
        // This is the mistake the first version of this DSP shipped with: at 300%
        // gain it measured quieter than at 100%. Keeping it as a test so the
        // reason the makeup exists cannot be edited away by accident.
        let compressor = Compressor()
        compressor.prepare(sampleRate: 48_000)
        #expect(compressor.makeup > 1)
    }
}
