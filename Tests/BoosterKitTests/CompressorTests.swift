import Testing
@testable import BoosterKit

@Suite("Compresor")
struct CompressorTests {

    @Test("bajo el umbral no toca nada")
    func belowThreshold() {
        let compressor = Compressor()
        #expect(compressor.staticReductionDecibels(forLevel: -40) == 0)
        #expect(compressor.staticReductionDecibels(forLevel: -30) == 0)
    }

    @Test("pasada la rodilla la curva sigue el ratio")
    func aboveKnee() {
        let compressor = Compressor()   // umbral -18, ratio 4:1, rodilla 6
        // 18 dB sobre el umbral a 4:1 devuelve un cuarto: −13,5 dB.
        #expect(abs(compressor.staticReductionDecibels(forLevel: 0) - -13.5) < 0.01)
    }

    @Test("la rodilla es continua en las dos puntas")
    func kneeIsContinuous() {
        let compressor = Compressor()
        let halfKnee = compressor.kneeDecibels / 2
        let lower = compressor.thresholdDecibels - halfKnee
        let upper = compressor.thresholdDecibels + halfKnee
        // Llegar a la rodilla desde afuera tiene que dar el valor de la rodilla.
        #expect(abs(compressor.staticReductionDecibels(forLevel: lower - 0.001)
                    - compressor.staticReductionDecibels(forLevel: lower + 0.001)) < 0.01)
        #expect(abs(compressor.staticReductionDecibels(forLevel: upper - 0.001)
                    - compressor.staticReductionDecibels(forLevel: upper + 0.001)) < 0.01)
    }

    @Test("el makeup devuelve exactamente lo que la curva saca a fondo de escala")
    func makeupCompensatesTheCurve() {
        let compressor = Compressor()
        compressor.prepare(sampleRate: 48_000)
        let takenAtFullScale = compressor.staticReductionDecibels(forLevel: 0)
        #expect(abs(linearToDecibels(compressor.makeup) + takenAtFullScale) < 0.01)
    }

    @Test("un compresor sin makeup haría el audio más bajo")
    func makeupIsNotOptional() {
        // Este es el error con el que salió la primera versión de este DSP: a
        // 300% de ganancia medía más bajo que a 100%. Queda como test para que la
        // razón por la que el makeup existe no se borre sin querer.
        let compressor = Compressor()
        compressor.prepare(sampleRate: 48_000)
        #expect(compressor.makeup > 1)
    }
}
